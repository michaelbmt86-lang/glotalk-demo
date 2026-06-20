import os
import asyncio
from livetranslate_client import LiveTranslateClient

async def main():
    api_key = os.environ.get("DASHSCOPE_API_KEY")
    if not api_key:
        print("[ERROR] 请设置环境变量 DASHSCOPE_API_KEY")
        return

    # GloTalk alibaba-v1 配置
    # 中文 → 英文，男声 Nofish
    client = LiveTranslateClient(
        api_key=api_key,
        target_language="en",
        voice="Nofish",
        audio_enabled=True
    )

    def on_translation(text):
        print(f"[翻译] {text}", flush=True)

    try:
        print("正在连接阿里云 qwen3-livetranslate-flash-realtime...")
        await client.connect()
        client.start_audio_player()
        print("连接成功！请对着麦克风说中文，按 Ctrl+C 退出。")

        message_task = asyncio.create_task(
            client.handle_server_messages(on_translation)
        )
        mic_task = asyncio.create_task(
            client.start_microphone_streaming()
        )
        await asyncio.gather(message_task, mic_task)

    except KeyboardInterrupt:
        print("\n退出中...")
    finally:
        await client.close()

if __name__ == "__main__":
    asyncio.run(main())
