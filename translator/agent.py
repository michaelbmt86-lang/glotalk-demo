"""
GloTalk Translator Agent - v2
"""

import asyncio
import logging
import os
from dataclasses import dataclass, field
from typing import Optional

from dotenv import load_dotenv
from livekit import rtc
from livekit.agents import cli, JobContext, WorkerOptions
from livekit.plugins import google

load_dotenv()

logger = logging.getLogger("glotalk-translator")

GEMINI_MODEL = "gemini-3.5-live-translate-preview"
ATTR_LANG = "lang"
RECONCILE_DEBOUNCE = 0.25

SUPPORTED_LANGUAGES= {
    "zh": "Chinese",
    "en": "English",
    "ja": "Japanese",
    "ko": "Korean",
    "es": "Spanish",
    "fr": "French",
    "de": "German",
    "pt": "Portuguese",
    "ar": "Arabic",
    "hi": "Hindi",
    "th": "Thai",
    "vi": "Vietnamese",
    "id": "Indonesian",
    "ms": "Malay",
    "ru": "Russian",
    "it": "Italian",
}


@dataclass
class GeminiTranslationSession:
    speaker_identity: str
    target_lang: str
    room: rtc.Room
    gemini_api_key: str

    _task: Optional[asyncio.Task] = field(default=None, init=False)
    _audio_source: Optional[rtc.AudioSource] = field(default=None, init=False)
    _local_track: Optional[rtc.LocalAudioTrack] = field(default=None, init=False)
    _closed: bool = field(default=False, init=False)

    @property
    def track_name(self) -> str:
        return f"tx:{self.speaker_identity}:{self.target_lang}"

    async def start(self, audio_stream: rtc.AudioStream) -> None:
        self._audio_source = rtc.AudioSource(sample_rate=24000, num_channels=1)
        self._local_track = rtc.LocalAudioTrack.create_audio_track(
            self.track_name, self._audio_source
        )
        options = rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE)
        await self.room.local_participant.publish_track(self._local_track, options)
        logger.info(f"[{self.track_name}] track published")
        self._task = asyncio.create_task(self._run_translation(audio_stream))

    async def _run_translation(self, audio_stream: rtc.AudioStream) -> None:
        try:
            client = google.realtime.RealtimeModel(
                model=GEMINI_MODEL,
                api_key=self.gemini_api_key,
                translation_config={
                    "targetLanguageCode": self.target_lang,
                },
            )
            async with client.connect() as session:
                logger.info(f"[{self.track_name}] Gemini session started")
                await asyncio.gather(
                    self._send_audio(audio_stream, session),
                    self._receive_audio(session),
                )
        except asyncio.CancelledError:
            logger.info(f"[{self.track_name}] cancelled")
        except Exception as e:
            logger.error(f"[{self.track_name}] error: {e}")

    async def _send_audio(self, audio_stream: rtc.AudioStream, session) -> None:
        async for event in audio_stream:
            if self._closed:
                break
            if isinstance(event, rtc.AudioFrameEvent):
                await session.send_audio(event.frame)

    async def _receive_audio(self, session) -> None:
        async for response in session:
            if self._closed:
                break
            if hasattr(response, 'audio') and response.audio:
                await self._audio_source.capture_frame(response.audio)

    async def close(self) -> None:
        self._closed = True
        if self._task and not self._task.done():
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        if self._local_track:
            try:
                await self.room.local_participant.unpublish_track(self._local_track.sid)
            except Exception:
                pass
        logger.info(f"[{self.track_name}] closed")


class TranslationRouter:
    def __init__(self, room: rtc.Room, gemini_api_key: str):
        self.room = room
        self.gemini_api_key = gemini_api_key
        self._sessions: dict[tuple[str, str], GeminiTranslationSession] = {}
        self._debounce_handle: Optional[asyncio.TimerHandle] = None

    def schedule_reconcile(self) -> None:
        if self._debounce_handle:
            self._debounce_handle.cancel()
        loop = asyncio.get_event_loop()
        self._debounce_handle = loop.call_later(
            RECONCILE_DEBOUNCE, lambda: asyncio.create_task(self.reconcile())
        )

    async def reconcile(self) -> None:
        participants: dict[str, str] = {}
        for participant in self.room.remote_participants.values():
            lang = participant.attributes.get(ATTR_LANG, "")
            if lang and lang in SUPPORTED_LANGUAGES:
                participants[participant.identity] = lang

        logger.info(f"[Router] participants: {participants}")

        needed: set[tuple[str, str]] = set()
        for speaker_id, speaker_lang in participants.items():
            for listener_id, listener_lang in participants.items():
                if speaker_id != listener_id and speaker_lang != listener_lang:
                    needed.add((speaker_id, listener_lang))

        current = set(self._sessions.keys())

        for pair in current - needed:
            session = self._sessions.pop(pair)
            await session.close()

        for pair in needed - current:
            speaker_id, target_lang = pair
            speaker_participant = self.room.remote_participants.get(speaker_id)
            if not speaker_participant:
                continue

            audio_track = None
            for pub in speaker_participant.track_publications.values():
                if pub.kind == rtc.TrackKind.KIND_AUDIO and pub.track is not None:
                    audio_track = pub.track
                    break

            if not audio_track:
                logger.warning(f"[Router] no audio track for {speaker_id}")
                continue

            audio_stream = rtc.AudioStream(audio_track, sample_rate=16000, num_channels=1)
            session = GeminiTranslationSession(
                speaker_identity=speaker_id,
                target_lang=target_lang,
                room=self.room,
                gemini_api_key=self.gemini_api_key,
            )
            self._sessions[pair] = session
            await session.start(audio_stream)
            logger.info(f"[Router] started session: {pair}")

    async def close_all(self) -> None:
        for session in self._sessions.values():
            await session.close()
        self._sessions.clear()


async def entrypoint(ctx: JobContext) -> None:
    await ctx.connect()
    room = ctx.room
    gemini_api_key = os.environ["GEMINI_API_KEY"]
    logger.info(f"[Agent] connected to room: {room.name}")

    router = TranslationRouter(room, gemini_api_key)

    @room.on("participant_connected")
    def on_participant_connected(participant: rtc.RemoteParticipant) -> None:
        logger.info(f"[Agent] participant joined: {participant.identity}")
        router.schedule_reconcile()

    @room.on("participant_disconnected")
    def on_participant_disconnected(participant: rtc.RemoteParticipant) -> None:
        logger.info(f"[Agent] participant left: {participant.identity}")
        router.schedule_reconcile()

    @room.on("participant_attributes_changed")
    def on_attributes_changed(changed: dict[str, str], participant: rtc.Participant) -> None:
        if ATTR_LANG in changed:
            logger.info(f"[Agent] {participant.identity} lang changed: {changed[ATTR_LANG]}")
            router.schedule_reconcile()

    @room.on("track_subscribed")
    def on_track_subscribed(track: rtc.Track, publication: rtc.RemoteTrackPublication, participant: rtc.RemoteParticipant) -> None:
        if track.kind == rtc.TrackKind.KIND_AUDIO:
            logger.info(f"[Agent] subscribed to audio: {participant.identity}")
            router.schedule_reconcile()

    await router.reconcile()

    disconnect_future = asyncio.get_event_loop().create_future()

    @room.on("disconnected")
    def on_disconnected(_reason=None) -> None:
        if not disconnect_future.done():
            disconnect_future.set_result(None)

    try:
        await disconnect_future
    finally:
        logger.info("[Agent] room disconnected, cleaning up...")
        await router.close_all()


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )
    cli.run_app(
        WorkerOptions(entrypoint_fnc=entrypoint)
    )
