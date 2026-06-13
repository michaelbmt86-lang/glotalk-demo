require('dotenv').config({ path: '/var/www/glotalk/.env' });
module.exports = {
  apps: [{
    name: 'glotalk-server',
    script: '/var/www/glotalk/server.js',
    env: {
      NODE_ENV: 'production',
      ACCESS_TOKEN: process.env.ACCESS_TOKEN,
      ADMIN_PASS: process.env.ADMIN_PASS,
      GEMINI_API_KEY: process.env.GEMINI_API_KEY,
      OPENAI_API_KEY: process.env.OPENAI_API_KEY,
      GITHUB_TOKEN: process.env.GITHUB_TOKEN
    }
  }]
}
