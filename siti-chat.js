// Vercel Serverless Function: Siti text chat gateway.
// Required Vercel environment variables: OPENAI_API_KEY, SUPABASE_URL, SUPABASE_ANON_KEY.
const MAX_MESSAGE_CHARS = 4000;
const MAX_HISTORY_ITEMS = 12;
const MAX_HISTORY_CHARS = 12000;
const json = (res, status, body) => res.status(status).setHeader('Content-Type','application/json; charset=utf-8').json(body);

module.exports = async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return json(res, 405, { error: 'Gunakan metode POST.' });
  }
  const apiKey = process.env.OPENAI_API_KEY;
  const supabaseUrl = process.env.SUPABASE_URL;
  const supabaseAnonKey = process.env.SUPABASE_ANON_KEY;
  if (!apiKey || !supabaseUrl || !supabaseAnonKey) {
    return json(res, 503, { error: 'Backend belum dikonfigurasi. Admin perlu mengatur OPENAI_API_KEY, SUPABASE_URL, dan SUPABASE_ANON_KEY di Vercel Environment Variables.' });
  }
  const auth = String(req.headers.authorization || '');
  const match = auth.match(/^Bearer\s+(.+)$/i);
  if (!match) return json(res, 401, { error: 'Sesi pengguna diperlukan.' });
  // Validate the session token with Supabase Auth; do not trust a client-supplied role.
  try {
    const verify = await fetch(supabaseUrl.replace(/\/$/, '') + '/auth/v1/user', {
      headers: { 'apikey': supabaseAnonKey, 'Authorization': 'Bearer ' + match[1] }
    });
    if (!verify.ok) return json(res, 401, { error: 'Sesi Supabase tidak valid atau sudah kedaluwarsa.' });
    const user = await verify.json().catch(() => ({}));
    if (user.is_anonymous === true) return json(res, 403, { error: 'Siti AI cloud memerlukan akun pengguna terautentikasi. Login simulasi/anonymous belum cukup aman untuk mengaktifkan penggunaan API berbiaya.' });
  } catch (_) { return json(res, 502, { error: 'Tidak dapat memvalidasi sesi pengguna.' }); }

  const body = req.body || {};
  const message = typeof body.message === 'string' ? body.message.trim() : '';
  if (!message) return json(res, 400, { error: 'Pesan tidak boleh kosong.' });
  if (message.length > MAX_MESSAGE_CHARS) return json(res, 413, { error: 'Pesan terlalu panjang (maksimum 4000 karakter).' });
  const rawHistory = Array.isArray(body.history) ? body.history.slice(-MAX_HISTORY_ITEMS) : [];
  let used = 0;
  const history = rawHistory.filter(x => x && ['user','assistant'].includes(x.role) && typeof x.content === 'string')
    .map(x => ({ role: x.role, content: x.content.slice(0, 3000) }))
    .filter(x => { used += x.content.length; return used <= MAX_HISTORY_CHARS; });
  const input = history.concat([{ role: 'user', content: message }]);
  try {
    const upstream = await fetch('https://api.openai.com/v1/responses', {
      method: 'POST',
      headers: { 'Authorization': 'Bearer ' + apiKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: process.env.OPENAI_MODEL || 'gpt-6-astra',
        instructions: 'Kamu adalah Siti, asisten AI untuk ekosistem Elquirazh ADV. Jawab dalam Bahasa Indonesia yang jelas, ramah, dan praktis. Jangan mengaku telah membaca data usaha, mengubah database, atau menjalankan tugas kecuali hasil tersebut benar-benar diberikan oleh sistem. Pada tahap ini kamu hanya memiliki percakapan teks; tidak ada akses langsung ke data operasional atau PC Worker. Jangan meminta rahasia, password, atau API key dari pengguna.',
        input,
        max_output_tokens: 900
      })
    });
    const data = await upstream.json().catch(() => ({}));
    if (!upstream.ok) {
      const msg = data?.error?.message || 'Layanan OpenAI gagal memproses pesan.';
      return json(res, upstream.status === 429 ? 429 : 502, { error: msg });
    }
    const reply = (data.output || []).flatMap(item => item.content || []).filter(c => c.type === 'output_text').map(c => c.text || '').join('\n').trim();
    if (!reply) return json(res, 502, { error: 'Tidak ada teks jawaban dari model.' });
    return json(res, 200, { reply, model: process.env.OPENAI_MODEL || 'gpt-6-astra' });
  } catch (_) { return json(res, 502, { error: 'Koneksi ke layanan OpenAI gagal. Coba lagi sebentar.' }); }
};
