require('dotenv').config({ path: '/var/www/glotalk/.env' });
module.exports = {
  apps: [
    // 主服务器（旧版，保留兼容）
    {
      name: 'glotalk-server',
      script: '/var/www/glotalk/server.js',
      env: {
        NODE_ENV: 'production',
        ACCESS_TOKEN: process.env.ACCESS_TOKEN,
        ADMIN_PASS: process.env.ADMIN_PASS,
        GEMINI_API_KEY: process.env.GEMINI_API_KEY,
        OPENAI_API_KEY: process.env.OPENAI_API_KEY,
        GITHUB_TOKEN: process.env.GITHUB_TOKEN,
        LIVEKIT_API_KEY: process.env.LIVEKIT_API_KEY,
        LIVEKIT_API_SECRET: process.env.LIVEKIT_API_SECRET,
        LIVEKIT_URL: process.env.LIVEKIT_URL,
        DASHSCOPE_API_KEY: process.env.DASHSCOPE_API_KEY,
      }
    },
    // AL 独立服务器（alibaba项目，专属端口3001）
    {
      name: 'glotalk-al',
      script: '/var/www/glotalk/al/server.js',
      env: {
        NODE_ENV: 'production',
      }
    }
  ]
}
