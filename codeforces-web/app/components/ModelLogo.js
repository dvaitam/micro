const MODEL_LOGOS = [
  { match: 'anthropic', logo: 'https://www.anthropic.com/favicon.ico' },
  { match: 'claude', logo: 'https://www.anthropic.com/favicon.ico' },
  { match: 'gemini', logo: 'https://www.gstatic.com/lamda/images/gemini_favicon_f069958c85030456e93de685481c559f160ea06b.png' },
  { match: 'kimi', logo: 'https://www.moonshot.cn/favicon.ico' },
  { match: 'moonshotai', logo: 'https://www.moonshot.cn/favicon.ico' },
  { match: 'grok', logo: 'https://x.ai/favicon.ico' },
  { match: 'xai', logo: 'https://x.ai/favicon.ico' },
  { match: 'gpt', logo: 'https://cdn.openai.com/favicon.ico' },
  { match: 'openai', logo: 'https://cdn.openai.com/favicon.ico' },
  { match: 'o1', logo: 'https://cdn.openai.com/favicon.ico' },
  { match: 'o3', logo: 'https://cdn.openai.com/favicon.ico' },
  { match: 'o4', logo: 'https://cdn.openai.com/favicon.ico' },
  { match: 'deepseek', logo: 'https://www.deepseek.com/favicon.ico' },
  { match: 'qwen', logo: 'https://img.alicdn.com/imgextra/i1/O1CN01AKUdEM1GReZ4JMeCH_!!6000000000619-73-tps-16-16.ico' },
];

export function getModelLogo(modelName) {
  if (!modelName) return null;
  const lower = modelName.toLowerCase();
  for (const { match, logo } of MODEL_LOGOS) {
    if (lower.includes(match)) return logo;
  }
  return null;
}

export default function ModelLogo({ model }) {
  const logo = getModelLogo(model);
  if (!logo) return null;
  return (
    <img
      src={logo}
      alt=""
      width={16}
      height={16}
      style={{ verticalAlign: 'middle', marginRight: 6, borderRadius: 2 }}
    />
  );
}
