export default {
  fetch(request) {
    const url = new URL(request.url);
    return Response.json({ ok: true, path: url.pathname, runtime: "celld" });
  },
};
