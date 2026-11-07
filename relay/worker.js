/**
 * 轻小说文库中转（Cloudflare Worker）
 *
 * 作用：把你的请求换成 Cloudflare 的出口 IP 去打文库，并把结果缓存在边缘节点。
 * 文库按 IP 限流（每域名 10 秒 5 个请求），所以直连的天花板是「300 章约 5 分钟」；
 * 走这里之后，限流落在 Cloudflare 这一侧，且同一个地址第二次取直接命中缓存。
 *
 * 用法：
 *   1. Cloudflare 控制台 → Workers & Pages → Create → Worker
 *   2. 把这份代码整段粘进去 → Deploy
 *   3. 复制 https://<你的名字>.workers.dev
 *   4. App：文库页右上角 ⋯ → 中转加速 → 粘贴 → 保存
 *
 * 请求格式（App 自动生成，不用手拼）：
 *   https://<你的名字>.workers.dev?u=https%3A%2F%2Fwww.wenku8.cc%2Fbook%2F3330.htm
 *
 * 注意：这是给你个人用的通道，别公开分享地址；免费额度每天 10 万次请求，
 * 读书足够，公开给别人用可能被限流或滥用。
 */

const ALLOWED_HOSTS = [
  'www.wenku8.cc',
  'www.wenku8.net',
  'wenku8.cc',
  'wenku8.net',
  'img.wenku8.com',
];

// 正文页几乎不变，缓存久一点；图片也不变。
const TTL_SECONDS = 60 * 60 * 24 * 7;

const BROWSER_HEADERS = {
  'user-agent':
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) ' +
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
  accept:
    'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
  'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8',
};

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // 根路径给一个自检页，方便确认部署成功。
    if (!url.searchParams.get('u')) {
      return new Response(
        'wenku8 proxy ok\n用法: ?u=<urlencoded target url>',
        { headers: { 'content-type': 'text/plain; charset=utf-8' } },
      );
    }

    let target;
    try {
      target = new URL(url.searchParams.get('u'));
    } catch {
      return new Response('bad u parameter', { status: 400 });
    }

    // 只允许文库自己的域名：否则这就是个开放代理，会被人拿去干别的。
    if (!ALLOWED_HOSTS.includes(target.hostname)) {
      return new Response('host not allowed: ' + target.hostname, {
        status: 403,
      });
    }

    const cache = caches.default;
    // 缓存键按目标地址算，忽略调用方带的各种时间戳参数。
    const cacheKey = new Request(target.toString(), { method: 'GET' });
    const hit = await cache.match(cacheKey);
    if (hit) {
      const copy = new Response(hit.body, hit);
      copy.headers.set('x-proxy-cache', 'HIT');
      return copy;
    }

    const upstream = await fetch(target.toString(), {
      headers: { ...BROWSER_HEADERS, referer: target.origin + '/' },
      redirect: 'follow',
      cf: {
        // 首次回源时的缓存策略：文库的页面是一直有效的，图也是。
        cacheTtl: TTL_SECONDS,
        cacheEverything: true,
        // 换 IP 重试一次：出口节点有时正好在站点的冷却名单里。
        scrapeShield: false,
      },
    });

    const response = new Response(upstream.body, upstream);
    response.headers.set('x-proxy-cache', 'MISS');
    response.headers.set('access-control-allow-origin', '*');
    // 只有 200 才缓存：429/403 是临时的，缓存住会一直失败。
    if (upstream.status === 200) {
      response.headers.set('cache-control', `public, max-age=${TTL_SECONDS}`);
      ctx.waitUntil(cache.put(cacheKey, response.clone()));
    }
    return response;
  },
};