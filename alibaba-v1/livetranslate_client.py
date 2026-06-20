import os
import time
import base64
import asyncio
import json
import websockets
import pyaudio
import queue
import threading
import traceback

class LiveTranslateClient:
    def __init__(self, api_key: str, target_language: str = "en", voice: str | None = "Nofish", *, audio_enabled: bool = True):
        if not api_key:
            raise ValueError("API key cannot be empty.")
        self.api_key = api_key
        self.target_language = target_language
        self.audio_enabled = audio_enabled
        self.voice = voice if audio_enabled else "Nofish"
        self.ws = None
        self.api_url = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-livetranslate-flash-realtime"
        self.input_rate = 16000
        self.input_chunk = 1600
        self.input_format = pyaudio.paInt16
        self.input_channels = 1
        self.output_rate = 24000
        self.output_chunk = 2400
        self.output_format = pyaudio.paInt16
        self.output_channels = 1
        self.is_connected = False
        self.audio_player_thread = None
        self.audio_playback_queue = queue.Queue()
        self.pyaudio_instance = pyaudio.PyAudio()

    async def connect(self):
        headers = {"Authorization": f"Bearer {self.api_key}"}
        try:
            self.ws = await websockets.connect(self.api_url, additional_headers=headers)
            self.is_connected = True
            print(f"Connected: {self.api_url}")
            await self.configure_session()
        except Exception as e:
            print(f"Connection failed: {e}")
            self.is_connected = False
            raise

    async def configure_session(self):
        config = {
            "event_id": f"event_{int(time.time() * 1000)}",
            "type": "session.update",
            "session": {
                "modalities": ["text", "audio"] if self.audio_enabled else ["text"],
                **({"voice": self.voice} if self.audio_enabled and self.voice else {}),
                "input_audio_format": "pcm",
                "output_audio_format": "pcm",
                "input_audio_transcription": {
                    "model": "qwen3-asr-flash-realtime",
                    "language": "zh"
                },
                "translation": {
                    "language": self.target_language,
                }
            }
        }
        await self.ws.send(json.dumps(config))

    async def send_audio_chunk(self, audio_data: bytes):
        if not self.is_connected:
            return
        event = {
            "event_id": f"event_{int(time.time() * 1000)}",
            "type": "input_audio_buffer.append",
            "audio": base64.b64encode(audio_data).decode()
        }
        await self.ws.send(json.dumps(event))

    def _audio_player_task(self):
        stream = self.pyaudio_instance.open(
            format=self.output_format,
            channels=self.output_channels,
            rate=self.output_rate,
            output=True,
            frames_per_buffer=self.output_chunk,
        )
        try:
            while self.is_connected or not self.audio_playback_queue.empty():
                try:
                    audio_chunk = self.audio_playback_queue.get(timeout=0.1)
                    if audio_chunk is None:
                        break
                    stream.write(audio_chunk)
                    self.audio_playback_queue.task_done()
                except queue.Empty:
                    continue
        finally:
            stream.stop_stream()
            stream.close()

    def start_audio_player(self):
        if not self.audio_enabled:
            return
        if self.audio_player_thread is None or not self.audio_player_thread.is_alive():
            self.audio_player_thread = threading.Thread(target=self._audio_player_task, daemon=True)
            self.audio_player_thread.start()

    async def handle_server_messages(self, on_text_received):
        try:
            async for message in self.ws:
                event = json.loads(message)
                event_type = event.get("type")
                if event_type == "response.audio.delta" and self.audio_enabled:
                    audio_b64 = event.get("delta", "")
                    if audio_b64:
                        audio_data = base64.b64decode(audio_b64)
                        self.audio_playback_queue.put(audio_data)
                elif event_type == "conversation.item.input_audio_transcription.text":
                    stash = event.get("stash", "")
                    if stash:
                        print(f"[源语言识别中] {stash}")
                elif event_type == "conversation.item.input_audio_transcription.completed":
                    transcript = event.get("transcript", "")
                    if transcript:
                        print(f"[源语言] {transcript}")
                elif event_type == "response.audio_transcript.done":
                    text = event.get("transcript", "")
                    if text:
                        print(f"[翻译结果] {text}")
                        on_text_received(text)
                elif event_type == "response.text.done":
                    text = event.get("text", "")
                    if text:
                        print(f"[翻译结果] {text}")
                        on_text_received(text)
                elif event_type == "response.done":
                    print("[一轮翻译完成]")
        except websockets.exceptions.ConnectionClosed as e:
            print(f"Connection closed: {e}")
            self.is_connected = False
        except Exception as e:
            print(f"Error: {e}")
            traceback.print_exc()
            self.is_connected = False

    async def start_microphone_streaming(self):
        stream = self.pyaudio_instance.open(
            format=self.input_format,
            channels=self.input_channels,
            rate=self.input_rate,
            input=True,
            frames_per_buffer=self.input_chunk
        )
        print("麦克风已启动，请开始说话...")
        try:
            while self.is_connected:
                audio_chunk = await asyncio.get_event_loop().run_in_executor(
                    None, stream.read, self.input_chunk
                )
                await self.send_audio_chunk(audio_chunk)
        finally:
            stream.stop_stream()
            stream.close()

    async def close(self):
        self.is_connected = False
        if self.ws:
            await self.ws.close()
        if self.audio_player_thread:
            self.audio_playback_queue.put(None)
            self.audio_player_thread.join(timeout=1)
        self.pyaudio_instance.terminate()
