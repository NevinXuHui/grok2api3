/**
 * Grok2API Cloudflare Worker Proxy
 * 
 * 功能：
 * 1. 代理请求到后端 grok2api 实例
 * 2. 处理 CORS 跨域请求
 * 3. 支持 Server-Sent Events (SSE) 流式返回
 */

const BACKEND_URL = "https://your-grok2api-instance.com"; // 替换为你的后端地址
const API_KEY = ""; // 可选：如果后端开启了认证，可以在这里硬编码或通过 KV/环境变量传入

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const targetUrl = new URL(url.pathname + url.search, BACKEND_URL);

    // 处理 OPTIONS 预检请求
    if (request.method === "OPTIONS") {
      return handleOptions(request);
    }

    const newRequest = new Request(targetUrl, {
      method: request.method,
      headers: new Headers(request.headers),
      body: request.body,
      redirect: "follow",
    });

    // 如果后端需要 API Key，可以在这里注入
    // if (API_KEY) {
    //   newRequest.headers.set("Authorization", `Bearer ${API_KEY}`);
    // }

    try {
      const response = await fetch(newRequest);
      
      // 克隆响应以修改头部（例如 CORS）
      const newResponse = new Response(response.body, response);
      newResponse.headers.set("Access-Control-Allow-Origin", "*");
      newResponse.headers.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS, DELETE, PUT");
      newResponse.headers.set("Access-Control-Allow-Headers", "*");

      return newResponse;
    } catch (e) {
      return new Response(JSON.stringify({ error: "Proxy connection failed", detail: e.message }), {
        status: 502,
        headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
      });
    }
  },
};

function handleOptions(request) {
  return new Response(null, {
    status: 204,
    headers: {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS, DELETE, PUT",
      "Access-Control-Allow-Headers": "*",
      "Access-Control-Max-Age": "86400",
    },
  });
}
