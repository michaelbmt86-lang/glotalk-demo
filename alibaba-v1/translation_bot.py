"""
GloTalk Translation Bot v2
参考：google-gemini/gemini-live-api-examples/gemini-live-translate-livekit
架构：LiveKit AudioStream → 阿里云 qwen3.5-livetranslate → LiveKit AudioSource
新增：用户离开时自动退出
"""
import asyncio
import array
import base64
import json
import os
import logging
import websockets
from livekit import rtc, api

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger('glotalk-bot')

LIVEKIT_URL = os.environ.get('LIVEKIT_URL', 'wss://glotalk-nppyx7kk.livekit.cloud')
LIVEKIT_API_KEY = os.environ.get('LIVEKIT_API_KEY', 'APIjE29k6cmBgda')
LIVEKIT_API_SECRET = os.environ.get('LIVEKIT_API_SECRET', '7eWFApcoDoDF4HXIPqx5qzz7aQ1GWDSiE5ynBjvUf4Z')
DASHSCOPE_API_KEY = os.environ.get('DASHSCOPE_API_KEY')
ALIBABA_WS_URL = 'wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3.5-livetranslate-flash-realtime'

INPUT_SAMPLE_RATE = 16000
OUTPUT_SAMPLE_RATE = 24000
FRAME_SIZE_MS = 100


class TranslationBridge:
    def __init__(self, room, participant, source_lang, target_lang, voice='Tina'):
        self.room = room
        self.participant = participant
        self.source_lang = source_lang
        self.target_lang = target_lang
        self.voice = voice
        self.audio_source = rtc.AudioSource(OUTPUT_SAMPLE_RATE, 1)
        self.running = False

    async def start(self, track):
        self.running = True
        bot_name = f'translation-{self.target_lang}'
        logger.info(f'[Bot] 启动翻译桥: {self.participant.identity} → {self.target_lang}')

        local_track = rtc.LocalAudioTrack.create_audio_track(bot_name, self.audio_source)
        pub_options = rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE)
        await self.room.local_participant.publish_track(local_track, pub_options)
        logger.info(f'[Bot] 翻译音轨已发布: {bot_name}')

        async with websockets.connect(
            ALIBABA_WS_URL,
            additional_headers={'Authorization': f'Bearer {DASHSCOPE_API_KEY}'}
        ) as ali_ws:
            self.ali_ws = ali_ws
            logger.info('[Bot] 已连接阿里云')

            await ali_ws.send(json.dumps({
                'event_id': 'evt_init',
                'type': 'session.update',
                'session': {
                    'modalities': ['text', 'audio'],
                    'voice': self.voice,
                    'input_audio_format': 'pcm',
                    'output_audio_format': 'pcm',
                    'input_audio_transcription': {
                        'model': 'qwen3-asr-flash-realtime',
                        'language': self.source_lang
                    },
                    'translation': {'language': self.target_lang}
                }
            }))

            await asyncio.gather(
                self._stream_audio(track, ali_ws),
                self._receive_translation(ali_ws)
            )

    async def _stream_audio(self, track, ali_ws):
        audio_stream = rtc.AudioStream(
            track,
            sample_rate=INPUT_SAMPLE_RATE,
            num_channels=1,
            frame_size_ms=FRAME_SIZE_MS
        )
        async for frame_event in audio_stream:
            if not self.running:
                break
            pcm_bytes = bytes(frame_event.frame.data)
            b64 = base64.b64encode(pcm_bytes).decode()
            await ali_ws.send(json.dumps({
                'event_id': 'evt_audio',
                'type': 'input_audio_buffer.append',
                'audio': b64
            }))

    async def _receive_translation(self, ali_ws):
        async for msg in ali_ws:
            if not self.running:
                break
            text = msg if isinstance(msg, str) else msg.decode()
            ev = json.loads(text)
            ev_type = ev.get('type', '')

            if ev_type in ('session.created', 'session.updated'):
                logger.info(f'[Bot] {ev_type}')
            elif ev_type == 'response.audio.delta':
                delta = ev.get('delta', '')
                if delta:
                    pcm = base64.b64decode(delta)
                    samples = array.array('h', pcm)
                    frame = rtc.AudioFrame(
                        data=bytes(samples),
                        sample_rate=OUTPUT_SAMPLE_RATE,
                        num_channels=1,
                        samples_per_channel=len(samples)
                    )
                    await self.audio_source.capture_frame(frame)
            elif ev_type == 'response.audio_transcript.done':
                logger.info(f'[Bot] 翻译: {ev.get("transcript", "")}')

    def stop(self):
        self.running = False


async def run_bot(room_name, source_lang, target_lang, participant_identity, voice='Tina'):
    token = api.AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET)
    token.with_identity(f'bot-{participant_identity}-{target_lang}')
    token.with_name(f'Translator ({target_lang})')
    token.with_grants(api.VideoGrants(room_join=True, room=room_name))
    jwt = token.to_jwt()

    room = rtc.Room()
    participant_left = asyncio.Event()
    active_bridge = None

    @room.on('track_subscribed')
    def on_track_subscribed(track, publication, participant):
        nonlocal active_bridge
        if (participant.identity == participant_identity and
                track.kind == rtc.TrackKind.KIND_AUDIO):
            logger.info(f'[Bot] 订阅到 {participant_identity} 的音轨')
            active_bridge = TranslationBridge(room, participant, source_lang, target_lang, voice)
            asyncio.ensure_future(active_bridge.start(track))

    @room.on('participant_disconnected')
    def on_participant_disconnected(participant):
        if participant.identity == participant_identity:
            logger.info(f'[Bot] 用户 {participant_identity} 已离开，Bot 退出')
            if active_bridge:
                active_bridge.stop()
            participant_left.set()

    await room.connect(LIVEKIT_URL, jwt)
    logger.info(f'[Bot] 已加入房间: {room_name}')

    try:
        await asyncio.wait_for(participant_left.wait(), timeout=3600)
    except asyncio.TimeoutError:
        logger.info(f'[Bot] 超时1小时，自动退出')
    finally:
        await room.disconnect()
        logger.info(f'[Bot] 已退出: {room_name}')


if __name__ == '__main__':
    import sys
    if len(sys.argv) < 5:
        print('用法: python3 translation_bot.py <room> <source_lang> <target_lang> <participant>')
        sys.exit(1)

    asyncio.run(run_bot(
        sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4],
        sys.argv[5] if len(sys.argv) > 5 else 'Tina'
    ))
