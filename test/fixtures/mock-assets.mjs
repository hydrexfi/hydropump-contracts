globalThis.fetch = async () => ({ ok: true, json: async () => JSON.parse(process.env.AUDIT_ASSETS) });
