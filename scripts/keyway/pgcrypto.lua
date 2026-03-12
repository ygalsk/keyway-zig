-- keyway.pgcrypto — SCRAM-SHA-256 crypto for pgmoon via LuaJIT FFI
-- Replaces luaossl dependency by calling libcrypto directly.
-- Provides the openssl.digest, openssl.hmac, openssl.kdf, openssl.rand
-- interfaces that pgmoon's crypto.lua probes for.

local ffi = require("ffi")
local b64 = require("mime").b64
local unb64 = require("mime").unb64

ffi.cdef[[
/* EVP digest */
typedef struct evp_md_ctx_st EVP_MD_CTX;
typedef struct evp_md_st EVP_MD;
const EVP_MD *EVP_sha256(void);
const EVP_MD *EVP_md5(void);
EVP_MD_CTX *EVP_MD_CTX_new(void);
void EVP_MD_CTX_free(EVP_MD_CTX *ctx);
int EVP_DigestInit_ex(EVP_MD_CTX *ctx, const EVP_MD *type, void *impl);
int EVP_DigestUpdate(EVP_MD_CTX *ctx, const void *d, size_t cnt);
int EVP_DigestFinal_ex(EVP_MD_CTX *ctx, unsigned char *md, unsigned int *s);

/* HMAC (EVP_MAC API — OpenSSL 3.0+) */
typedef struct evp_mac_st EVP_MAC;
typedef struct evp_mac_ctx_st EVP_MAC_CTX;
typedef struct ossl_lib_ctx_st OSSL_LIB_CTX;
typedef struct ossl_param_st {
    const char *key;
    unsigned int data_type;
    void *data;
    size_t data_size;
    size_t return_size;
} OSSL_PARAM;
EVP_MAC *EVP_MAC_fetch(OSSL_LIB_CTX *libctx, const char *algorithm, const char *properties);
EVP_MAC_CTX *EVP_MAC_CTX_new(EVP_MAC *mac);
void EVP_MAC_CTX_free(EVP_MAC_CTX *ctx);
void EVP_MAC_free(EVP_MAC *mac);
int EVP_MAC_init(EVP_MAC_CTX *ctx, const unsigned char *key, size_t keylen, const OSSL_PARAM params[]);
int EVP_MAC_update(EVP_MAC_CTX *ctx, const unsigned char *data, size_t datalen);
int EVP_MAC_final(EVP_MAC_CTX *ctx, unsigned char *out, size_t *outl, size_t outsize);
OSSL_PARAM OSSL_PARAM_construct_utf8_string(const char *key, char *buf, size_t bsize);
OSSL_PARAM OSSL_PARAM_construct_end(void);

/* PBKDF2 */
int PKCS5_PBKDF2_HMAC(const char *pass, int passlen,
                       const unsigned char *salt, int saltlen,
                       int iter, const EVP_MD *digest,
                       int keylen, unsigned char *out);

/* Random */
int RAND_bytes(unsigned char *buf, int num);
]]

local C = ffi.C

-- openssl.digest shim
local digest_mod = {}
local digest_mt = { __index = {} }

function digest_mod.new(algo)
    local md
    if algo == "sha256" then md = C.EVP_sha256()
    elseif algo == "md5" then md = C.EVP_md5()
    else error("unsupported digest: " .. algo) end

    local ctx = C.EVP_MD_CTX_new()
    if ctx == nil then error("EVP_MD_CTX_new failed") end
    ffi.gc(ctx, C.EVP_MD_CTX_free)
    if C.EVP_DigestInit_ex(ctx, md, nil) ~= 1 then error("EVP_DigestInit_ex failed") end
    return setmetatable({ ctx = ctx, md = md }, digest_mt)
end

function digest_mt.__index:update(data)
    if C.EVP_DigestUpdate(self.ctx, data, #data) ~= 1 then error("EVP_DigestUpdate failed") end
    return self
end

function digest_mt.__index:final(data)
    if data then self:update(data) end
    local buf = ffi.new("unsigned char[64]")
    local len = ffi.new("unsigned int[1]")
    if C.EVP_DigestFinal_ex(self.ctx, buf, len) ~= 1 then error("EVP_DigestFinal_ex failed") end
    return ffi.string(buf, len[0])
end

-- openssl.hmac shim (uses EVP_MAC API for OpenSSL 3.0+)
local hmac_mod = {}
local hmac_mt = { __index = {} }

function hmac_mod.new(key, algo)
    local mac = C.EVP_MAC_fetch(nil, "HMAC", nil)
    if mac == nil then error("EVP_MAC_fetch HMAC failed") end

    local ctx = C.EVP_MAC_CTX_new(mac)
    if ctx == nil then
        C.EVP_MAC_free(mac)
        error("EVP_MAC_CTX_new failed")
    end

    -- Build params: digest name
    local algo_str = ffi.new("char[?]", #algo + 1, algo)
    local params = ffi.new("OSSL_PARAM[2]")
    params[0] = C.OSSL_PARAM_construct_utf8_string("digest", algo_str, 0)
    params[1] = C.OSSL_PARAM_construct_end()

    if C.EVP_MAC_init(ctx, ffi.cast("const unsigned char*", key), #key, params) ~= 1 then
        C.EVP_MAC_CTX_free(ctx)
        C.EVP_MAC_free(mac)
        error("EVP_MAC_init failed")
    end

    ffi.gc(ctx, C.EVP_MAC_CTX_free)
    return setmetatable({ ctx = ctx, mac = mac }, hmac_mt)
end

function hmac_mt.__index:update(data)
    if C.EVP_MAC_update(self.ctx, ffi.cast("const unsigned char*", data), #data) ~= 1 then
        error("EVP_MAC_update failed")
    end
    return self
end

function hmac_mt.__index:final()
    local buf = ffi.new("unsigned char[64]")
    local outl = ffi.new("size_t[1]")
    if C.EVP_MAC_final(self.ctx, buf, outl, 64) ~= 1 then error("EVP_MAC_final failed") end
    -- Clean up the MAC object (ctx is gc'd)
    C.EVP_MAC_free(self.mac)
    self.mac = nil
    return ffi.string(buf, outl[0])
end

-- openssl.kdf shim (PBKDF2 via PKCS5_PBKDF2_HMAC)
local kdf_mod = {}

function kdf_mod.derive(opts)
    local pass = opts.pass or ""
    local salt = opts.salt or ""
    local iter = opts.iter or 4096
    local outlen = opts.outlen or 32
    local md
    if opts.md == "sha256" then md = C.EVP_sha256()
    else error("unsupported kdf digest: " .. tostring(opts.md)) end

    local out = ffi.new("unsigned char[?]", outlen)
    local rc = C.PKCS5_PBKDF2_HMAC(pass, #pass,
        ffi.cast("const unsigned char*", salt), #salt,
        iter, md, outlen, out)
    if rc ~= 1 then return nil, "PKCS5_PBKDF2_HMAC failed" end
    return ffi.string(out, outlen)
end

-- openssl.rand shim
local rand_mod = {}

function rand_mod.bytes(n)
    local buf = ffi.new("unsigned char[?]", n)
    if C.RAND_bytes(buf, n) ~= 1 then error("RAND_bytes failed") end
    return ffi.string(buf, n)
end

-- Install shims into package.loaded so pgmoon's crypto.lua finds them
package.loaded["openssl.digest"] = digest_mod
package.loaded["openssl.hmac"]   = hmac_mod
package.loaded["openssl.kdf"]    = kdf_mod
package.loaded["openssl.rand"]   = rand_mod

return {
    digest = digest_mod,
    hmac   = hmac_mod,
    kdf    = kdf_mod,
    rand   = rand_mod,
}
