module.exports = {
  apps: [{
    name: 'glotalk-server',
    script: '/var/www/glotalk/server.js',
    env: {
      NODE_ENV: 'production',
      PORT: 3000,
      ACCESS_TOKEN: 'glotalk2026',
      ADMIN_PASS: 'gloAdmin2026',
      GEMINI_API_KEY: 'AQ.Ab8RN6JU1ty-morix50yd0cwhohKPzEIUxF7c-rrHKDKOwqQPg',
      OPENAI_API_KEY: '',
      GITHUB_TOKEN: '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'
    }
  }]
}
