"""
GloTalk Translation Bot
参考：google-gemini/gemini-live-api-examples/gemini-live-translate-livekit
架构：LiveKit AudioStream → 阿里云 qwen3.5-livetranslate → LiveKit AudioSource
"""
import asyncio
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
    def __init__(self, room: rtc.Room, participant: rtc.RemoteParticipant,
                 source_lang: str, target_lang: str, voice: str = 'Tina'):
        self.room = room
        self.participant = participant
        self.source_lang = source_lang
        self.target_lang = target_lang
        self.voice = voice
        self.ali_ws = None
        self.audio_source = rtc.AudioSource(OUTPUT_SAMPLE_RATE, 1)
        self.running = False

    async def start(self, track: rtc.Track):
        self.running = True
        bot_name = f'translator-{self.participant.identity}-{self.target_lang}'
        logger.info(f'[Bot] 启动翻译桥: {self.participant.identity} → {self.target_lang}')

        # 发布翻译音轨到 LiveKit
        local_track = rtc.LocalAudioTrack.create_audio_track(bot_name, self.audio_source)
        pub_options = rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE)
        await self.room.local_participant.publish_track(local_track, pub_options)
        logger.info(f'[Bot] 翻译音轨已发布: {bot_name}')

        # 连接阿里云
        async with websockets.connect(
            ALIBABA_WS_URL,
            additional_headers={'Authorization': f'Bearer {DASHSCOPE_API_KEY}'}
        ) as ali_ws:
            self.ali_ws = ali_ws
            logger.info('[Bot] 已连接阿里云')

            # 发送 session.update
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

            # 并发：接收音频 + 接收翻译
            await asyncio.gather(
                self._stream_audio(track, ali_ws),
                self._receive_translation(ali_ws)
            )

    async def _stream_audio(self, track: rtc.Track, ali_ws):
        """订阅 LiveKit 音频 → 转发给阿里云"""
        audio_stream = rtc.AudioStream(
            track,
            sample_rate=INPUT_SAMPLE_RATE,
            num_channels=1,
            frame_size_ms=FRAME_SIZE_MS
        )
        async for frame_event in audio_stream:
            if not self.running:
                break
            frame = frame_event.frame
            pcm_bytes = bytes(frame.data)
            b64 = base64.b64encode(pcm_bytes).decode()
            await ali_ws.send(json.dumps({
                'event_id': 'evt_audio',
                'type': 'input_audio_buffer.append',
                'audio': b64
            }))

    async def _receive_translation(self, ali_ws):
        """接收阿里云翻译音频 → 发布到 LiveKit"""
        async for msg in ali_ws:
            text = msg if isinstance(msg, str) else msg.decode()
            ev = json.loads(text)
            ev_type = ev.get('type', '')

            if ev_type == 'session.created':
                logger.info('[Bot] 阿里云 session 创建成功')
            elif ev_type == 'session.updated':
                logger.info('[Bot] 阿里云 session 配置完成')
            elif ev_type == 'response.audio.delta':
                delta = ev.get('delta', '')
                if delta:
                    pcm = base64.b64decode(delta)
                    # 转成 int16 frame 发布到 LiveKit
                    import array
                    samples = array.array('h', pcm)
                    samples_per_channel = len(samples)
                    frame = rtc.AudioFrame(
                        data=bytes(samples),
                        sample_rate=OUTPUT_SAMPLE_RATE,
                        num_channels=1,
                        samples_per_channel=samples_per_channel
                    )
                    await self.audio_source.capture_frame(frame)
            elif ev_type == 'response.audio_transcript.done':
                logger.info(f'[Bot] 翻译完成: {ev.get("transcript", "")}')

    def stop(self):
        self.running = False


async def run_bot(room_name: str, source_lang: str, target_lang: str,
                  participant_identity: str, voice: str = 'Tina'):
    """Bot 加入房间，等待指定用户的音轨，开始翻译"""

    # 生成 Bot token
    token = api.AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET)
    token.with_identity(f'bot-{participant_identity}-{target_lang}')
    token.with_name(f'Translator ({target_lang})')
    token.with_grants(api.VideoGrants(room_join=True, room=room_name))
    jwt = token.to_jwt()

    room = rtc.Room()
    bridge = None

    @room.on('track_subscribed')
    def on_track_subscribed(track, publication, participant):
        nonlocal bridge
        if (participant.identity == participant_identity and
                track.kind == rtc.TrackKind.KIND_AUDIO):
            logger.info(f'[Bot] 订阅到 {participant_identity} 的音轨')
            bridge = TranslationBridge(room, participant, source_lang, target_lang, voice)
            asyncio.ensure_future(bridge.start(track))

    await room.connect(LIVEKIT_URL, jwt)
    logger.info(f'[Bot] 已加入房间: {room_name}')

    # 保持运行直到断开
    try:
        await asyncio.sleep(3600)  # 最多1小时
    finally:
        await room.disconnect()
        logger.info('[Bot] 已退出房间')


if __name__ == '__main__':
    import sys
    if len(sys.argv) < 5:
        print('用法: python3 translation_bot.py <room> <source_lang> <target_lang> <participant>')
        print('例子: python3 translation_bot.py glotalk-room zh en user-alice Tina')
        sys.exit(1)

    room_name = sys.argv[1]
    source_lang = sys.argv[2]
    target_lang = sys.argv[3]
    participant_identity = sys.argv[4]
    voice = sys.argv[5] if len(sys.argv) > 5 else 'Tina'

    asyncio.run(run_bot(room_name, source_lang, target_lang, participant_identity, voice))
