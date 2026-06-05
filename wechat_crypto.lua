local M = {}

local HEX = "0123456789abcdef"
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_MAP = {}

for i = 1, #B64 do
  B64_MAP[B64:sub(i, i)] = i - 1
end

local MD5_S = {
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

local MD5_K = {
  "0xd76aa478", "0xe8c7b756", "0x242070db", "0xc1bdceee",
  "0xf57c0faf", "0x4787c62a", "0xa8304613", "0xfd469501",
  "0x698098d8", "0x8b44f7af", "0xffff5bb1", "0x895cd7be",
  "0x6b901122", "0xfd987193", "0xa679438e", "0x49b40821",
  "0xf61e2562", "0xc040b340", "0x265e5a51", "0xe9b6c7aa",
  "0xd62f105d", "0x02441453", "0xd8a1e681", "0xe7d3fbc8",
  "0x21e1cde6", "0xc33707d6", "0xf4d50d87", "0x455a14ed",
  "0xa9e3e905", "0xfcefa3f8", "0x676f02d9", "0x8d2a4c8a",
  "0xfffa3942", "0x8771f681", "0x6d9d6122", "0xfde5380c",
  "0xa4beea44", "0x4bdecfa9", "0xf6bb4b60", "0xbebfbc70",
  "0x289b7ec6", "0xeaa127fa", "0xd4ef3085", "0x04881d05",
  "0xd9d4d039", "0xe6db99e5", "0x1fa27cf8", "0xc4ac5665",
  "0xf4292244", "0x432aff97", "0xab9423a7", "0xfc93a039",
  "0x655b59c3", "0x8f0ccc92", "0xffeff47d", "0x85845dd1",
  "0x6fa87e4f", "0xfe2ce6e0", "0xa3014314", "0x4e0811a1",
  "0xf7537e82", "0xbd3af235", "0x2ad7d2bb", "0xeb86d391",
}

local AES_SBOX = {
  0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
  0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
  0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
  0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
  0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
  0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
  0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
  0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
  0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
  0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
  0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
  0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
  0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
  0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
  0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
  0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
}

local AES_RCON = { 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36 }

local AES_INV_SBOX = {
  0x52, 0x09, 0x6a, 0xd5, 0x30, 0x36, 0xa5, 0x38, 0xbf, 0x40, 0xa3, 0x9e, 0x81, 0xf3, 0xd7, 0xfb,
  0x7c, 0xe3, 0x39, 0x82, 0x9b, 0x2f, 0xff, 0x87, 0x34, 0x8e, 0x43, 0x44, 0xc4, 0xde, 0xe9, 0xcb,
  0x54, 0x7b, 0x94, 0x32, 0xa6, 0xc2, 0x23, 0x3d, 0xee, 0x4c, 0x95, 0x0b, 0x42, 0xfa, 0xc3, 0x4e,
  0x08, 0x2e, 0xa1, 0x66, 0x28, 0xd9, 0x24, 0xb2, 0x76, 0x5b, 0xa2, 0x49, 0x6d, 0x8b, 0xd1, 0x25,
  0x72, 0xf8, 0xf6, 0x64, 0x86, 0x68, 0x98, 0x16, 0xd4, 0xa4, 0x5c, 0xcc, 0x5d, 0x65, 0xb6, 0x92,
  0x6c, 0x70, 0x48, 0x50, 0xfd, 0xed, 0xb9, 0xda, 0x5e, 0x15, 0x46, 0x57, 0xa7, 0x8d, 0x9d, 0x84,
  0x90, 0xd8, 0xab, 0x00, 0x8c, 0xbc, 0xd3, 0x0a, 0xf7, 0xe4, 0x58, 0x05, 0xb8, 0xb3, 0x45, 0x06,
  0xd0, 0x2c, 0x1e, 0x8f, 0xca, 0x3f, 0x0f, 0x02, 0xc1, 0xaf, 0xbd, 0x03, 0x01, 0x13, 0x8a, 0x6b,
  0x3a, 0x91, 0x11, 0x41, 0x4f, 0x67, 0xdc, 0xea, 0x97, 0xf2, 0xcf, 0xce, 0xf0, 0xb4, 0xe6, 0x73,
  0x96, 0xac, 0x74, 0x22, 0xe7, 0xad, 0x35, 0x85, 0xe2, 0xf9, 0x37, 0xe8, 0x1c, 0x75, 0xdf, 0x6e,
  0x47, 0xf1, 0x1a, 0x71, 0x1d, 0x29, 0xc5, 0x89, 0x6f, 0xb7, 0x62, 0x0e, 0xaa, 0x18, 0xbe, 0x1b,
  0xfc, 0x56, 0x3e, 0x4b, 0xc6, 0xd2, 0x79, 0x20, 0x9a, 0xdb, 0xc0, 0xfe, 0x78, 0xcd, 0x5a, 0xf4,
  0x1f, 0xdd, 0xa8, 0x33, 0x88, 0x07, 0xc7, 0x31, 0xb1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xec, 0x5f,
  0x60, 0x51, 0x7f, 0xa9, 0x19, 0xb5, 0x4a, 0x0d, 0x2d, 0xe5, 0x7a, 0x9f, 0x93, 0xc9, 0x9c, 0xef,
  0xa0, 0xe0, 0x3b, 0x4d, 0xae, 0x2a, 0xf5, 0xb0, 0xc8, 0xeb, 0xbb, 0x3c, 0x83, 0x53, 0x99, 0x61,
  0x17, 0x2b, 0x04, 0x7e, 0xba, 0x77, 0xd6, 0x26, 0xe1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0c, 0x7d,
}

local state = {
  md5_fn = nil,
  aes_fn = nil,
  aes_dec_fn = nil,
  sbox = nil,
  inv_sbox = nil,
  rcon = nil,
  key_buf = nil,
  rk = nil,
  md5_st = nil,
  bulk_api_checked = false,
}

local function byte_hex(b)
  b = tonumber(b) or 0
  return HEX:sub((b >> 4) + 1, (b >> 4) + 1) .. HEX:sub((b & 15) + 1, (b & 15) + 1)
end

local function bytes_to_hex(raw)
  raw = tostring(raw or "")
  local out = {}
  for i = 1, #raw do
    out[i] = byte_hex(raw:byte(i))
  end
  return table.concat(out)
end

local function hex_to_bytes(hex)
  hex = tostring(hex or ""):gsub("%s+", "")
  if (#hex % 2) ~= 0 then
    return nil, "hex length must be even"
  end
  local out = {}
  for i = 1, #hex, 2 do
    local n = tonumber(hex:sub(i, i + 1), 16)
    if not n then
      return nil, "invalid hex"
    end
    out[#out + 1] = string.char(n)
  end
  return table.concat(out), nil
end

local function base64_encode(raw)
  raw = tostring(raw or "")
  local parts = {}
  local out = {}
  local out_len = 0
  local function push(value)
    out_len = out_len + 1
    out[out_len] = value
    if out_len >= 1024 then
      parts[#parts + 1] = table.concat(out)
      out = {}
      out_len = 0
    end
  end
  for i = 1, #raw, 3 do
    local a = raw:byte(i) or 0
    local b = raw:byte(i + 1) or 0
    local c = raw:byte(i + 2) or 0
    local n = (a << 16) | (b << 8) | c
    local s1 = B64:sub(((n >> 18) & 63) + 1, ((n >> 18) & 63) + 1)
    local s2 = B64:sub(((n >> 12) & 63) + 1, ((n >> 12) & 63) + 1)
    local s3 = i + 1 <= #raw and B64:sub(((n >> 6) & 63) + 1, ((n >> 6) & 63) + 1) or "="
    local s4 = i + 2 <= #raw and B64:sub((n & 63) + 1, (n & 63) + 1) or "="
    push(s1 .. s2 .. s3 .. s4)
  end
  if out_len > 0 then
    parts[#parts + 1] = table.concat(out)
  end
  return table.concat(parts)
end

local function base64_decode(text)
  text = tostring(text or ""):gsub("%s+", "")
  local out = {}
  for i = 1, #text, 4 do
    local c1 = text:sub(i, i)
    local c2 = text:sub(i + 1, i + 1)
    local c3 = text:sub(i + 2, i + 2)
    local c4 = text:sub(i + 3, i + 3)
    if c1 == "" or c2 == "" then
      return nil, "bad base64"
    end
    local a = B64_MAP[c1]
    local b = B64_MAP[c2]
    local c = c3 == "=" and 0 or B64_MAP[c3]
    local d = c4 == "=" and 0 or B64_MAP[c4]
    if not a or not b or not c or not d then
      return nil, "bad base64"
    end
    local n = (a << 18) | (b << 12) | (c << 6) | d
    out[#out + 1] = string.char((n >> 16) & 255)
    if c3 ~= "=" then
      out[#out + 1] = string.char((n >> 8) & 255)
    end
    if c4 ~= "=" then
      out[#out + 1] = string.char(n & 255)
    end
  end
  return table.concat(out), nil
end

local function write_string_to_buf(buf, offset, raw)
  raw = tostring(raw or "")
  offset = tonumber(offset) or 0
  buf:from_string(raw, offset)
end

local function string_to_buf(raw)
  raw = tostring(raw or "")
  local buf = viper.buf(#raw > 0 and #raw or 1)
  buf:from_string(raw)
  return buf
end

local function buf_to_string(buf, len)
  return buf:to_string(0, len)
end

local function buf_to_hex(buf, len)
  return bytes_to_hex(buf:to_string(0, len))
end

local function write_le64_bits(buf, off, byte_len)
  local lo = (byte_len * 8) & 0xffffffff
  local hi = math.floor(byte_len / 0x20000000) & 0xffffffff
  buf:from_string(string.char(
    lo & 255,
    (lo >> 8) & 255,
    (lo >> 16) & 255,
    (lo >> 24) & 255,
    hi & 255,
    (hi >> 8) & 255,
    (hi >> 16) & 255,
    (hi >> 24) & 255
  ), off)
end

local function md5_message_buf(raw)
  local len = #raw
  local pad_zero = (56 - ((len + 1) % 64)) % 64
  local total = len + 1 + pad_zero + 8
  local buf = viper.buf(total)
  buf:from_string(raw)
  buf:from_string(string.char(0x80), len)
  write_le64_bits(buf, total - 8, len)
  return buf, total
end

local function pkcs7_message_buf(raw)
  local len = #raw
  local pad = 16 - (len % 16)
  if pad == 0 then
    pad = 16
  end
  local total = len + pad
  local buf = viper.buf(total)
  buf:from_string(raw)
  buf:from_string(string.rep(string.char(pad), pad), len)
  return buf, total
end

local function build_md5_src()
  local lines = {
    "void md5_blocks(uint8_t *buf, int32_t blocks, uint32_t *st) {",
    "  int32_t blk = 0;",
    "  int32_t off = 0;",
    "  uint32_t a = 0;",
    "  uint32_t b = 0;",
    "  uint32_t c = 0;",
    "  uint32_t d = 0;",
    "  uint32_t f = 0;",
    "  uint32_t t = 0;",
    "  uint32_t r = 0;",
  }
  for i = 0, 15 do
    lines[#lines + 1] = "  uint32_t m" .. i .. " = 0;"
  end
  lines[#lines + 1] = "  for (blk = 0; blk < blocks; blk = blk + 1) {"
  lines[#lines + 1] = "    off = blk * 64;"
  for i = 0, 15 do
    local b = i * 4
    lines[#lines + 1] = string.format(
      "    m%d = buf[off + %d] | (buf[off + %d] << 8) | (buf[off + %d] << 16) | (buf[off + %d] << 24);",
      i, b, b + 1, b + 2, b + 3
    )
  end
  lines[#lines + 1] = "    a = st[0];"
  lines[#lines + 1] = "    b = st[1];"
  lines[#lines + 1] = "    c = st[2];"
  lines[#lines + 1] = "    d = st[3];"
  for i = 0, 63 do
    local round = math.floor(i / 16)
    local g
    if round == 0 then
      g = i
      lines[#lines + 1] = "    f = (b & c) | ((~b) & d);"
    elseif round == 1 then
      g = ((5 * i) + 1) % 16
      lines[#lines + 1] = "    f = (d & b) | ((~d) & c);"
    elseif round == 2 then
      g = ((3 * i) + 5) % 16
      lines[#lines + 1] = "    f = b ^ c ^ d;"
    else
      g = (7 * i) % 16
      lines[#lines + 1] = "    f = c ^ (b | (~d));"
    end
    local s = MD5_S[i + 1]
    lines[#lines + 1] = "    t = a + f + " .. MD5_K[i + 1] .. " + m" .. g .. ";"
    lines[#lines + 1] = "    r = (t << " .. s .. ") | (t >> " .. (32 - s) .. ");"
    lines[#lines + 1] = "    a = d;"
    lines[#lines + 1] = "    d = c;"
    lines[#lines + 1] = "    c = b;"
    lines[#lines + 1] = "    b = b + r;"
  end
  lines[#lines + 1] = "    st[0] = st[0] + a;"
  lines[#lines + 1] = "    st[1] = st[1] + b;"
  lines[#lines + 1] = "    st[2] = st[2] + c;"
  lines[#lines + 1] = "    st[3] = st[3] + d;"
  lines[#lines + 1] = "  }"
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n")
end

local function build_aes_src()
  local lines = {
    "void aes128_ecb_encrypt(uint8_t *input, uint8_t *output, int32_t blocks, uint8_t *key, uint8_t *sbox, uint8_t *rcon, uint8_t *rk) {",
    "  int32_t i = 0;",
    "  int32_t r = 0;",
    "  int32_t blk = 0;",
    "  int32_t base = 0;",
    "  int32_t bytes = 0;",
    "  uint32_t t0 = 0;",
    "  uint32_t t1 = 0;",
    "  uint32_t t2 = 0;",
    "  uint32_t t3 = 0;",
  }
  for _, prefix in ipairs({ "s", "n" }) do
    for i = 0, 15 do
      lines[#lines + 1] = "  uint32_t " .. prefix .. i .. " = 0;"
    end
  end
  for i = 0, 3 do
    lines[#lines + 1] = "  uint32_t x" .. i .. " = 0;"
    lines[#lines + 1] = "  uint32_t y" .. i .. " = 0;"
  end
  lines[#lines + 1] = "  for (i = 0; i < 16; i = i + 1) {"
  lines[#lines + 1] = "    rk[i] = key[i];"
  lines[#lines + 1] = "  }"
  lines[#lines + 1] = "  bytes = 16;"
  lines[#lines + 1] = "  for (r = 0; r < 10; r = r + 1) {"
  lines[#lines + 1] = "    t0 = sbox[rk[bytes - 3]] ^ rcon[r];"
  lines[#lines + 1] = "    t1 = sbox[rk[bytes - 2]];"
  lines[#lines + 1] = "    t2 = sbox[rk[bytes - 1]];"
  lines[#lines + 1] = "    t3 = sbox[rk[bytes - 4]];"
  lines[#lines + 1] = "    rk[bytes] = rk[bytes - 16] ^ t0; bytes = bytes + 1;"
  lines[#lines + 1] = "    rk[bytes] = rk[bytes - 16] ^ t1; bytes = bytes + 1;"
  lines[#lines + 1] = "    rk[bytes] = rk[bytes - 16] ^ t2; bytes = bytes + 1;"
  lines[#lines + 1] = "    rk[bytes] = rk[bytes - 16] ^ t3; bytes = bytes + 1;"
  lines[#lines + 1] = "    for (i = 0; i < 12; i = i + 1) {"
  lines[#lines + 1] = "      rk[bytes] = rk[bytes - 16] ^ rk[bytes - 4];"
  lines[#lines + 1] = "      bytes = bytes + 1;"
  lines[#lines + 1] = "    }"
  lines[#lines + 1] = "  }"
  lines[#lines + 1] = "  for (blk = 0; blk < blocks; blk = blk + 1) {"
  lines[#lines + 1] = "    base = blk * 16;"
  for i = 0, 15 do
    lines[#lines + 1] = "    s" .. i .. " = input[base + " .. i .. "] ^ rk[" .. i .. "];"
  end
  lines[#lines + 1] = "    for (r = 1; r < 10; r = r + 1) {"
  local shift = { 0, 5, 10, 15, 4, 9, 14, 3, 8, 13, 2, 7, 12, 1, 6, 11 }
  for i = 0, 15 do
    lines[#lines + 1] = "      n" .. i .. " = sbox[s" .. shift[i + 1] .. "];"
  end
  local function xtime(v)
    return "((" .. v .. " << 1) ^ ((0 - ((" .. v .. " >> 7) & 1)) & 27)) & 255"
  end
  local function mix_col(offset)
    lines[#lines + 1] = "      x0 = n" .. offset .. ";"
    lines[#lines + 1] = "      x1 = n" .. (offset + 1) .. ";"
    lines[#lines + 1] = "      x2 = n" .. (offset + 2) .. ";"
    lines[#lines + 1] = "      x3 = n" .. (offset + 3) .. ";"
    lines[#lines + 1] = "      y0 = " .. xtime("x0") .. ";"
    lines[#lines + 1] = "      y1 = " .. xtime("x1") .. ";"
    lines[#lines + 1] = "      y2 = " .. xtime("x2") .. ";"
    lines[#lines + 1] = "      y3 = " .. xtime("x3") .. ";"
    lines[#lines + 1] = "      s" .. offset .. " = y0 ^ (y1 ^ x1) ^ x2 ^ x3 ^ rk[(r * 16) + " .. offset .. "];"
    lines[#lines + 1] = "      s" .. (offset + 1) .. " = x0 ^ y1 ^ (y2 ^ x2) ^ x3 ^ rk[(r * 16) + " .. (offset + 1) .. "];"
    lines[#lines + 1] = "      s" .. (offset + 2) .. " = x0 ^ x1 ^ y2 ^ (y3 ^ x3) ^ rk[(r * 16) + " .. (offset + 2) .. "];"
    lines[#lines + 1] = "      s" .. (offset + 3) .. " = (y0 ^ x0) ^ x1 ^ x2 ^ y3 ^ rk[(r * 16) + " .. (offset + 3) .. "];"
  end
  mix_col(0)
  mix_col(4)
  mix_col(8)
  mix_col(12)
  lines[#lines + 1] = "    }"
  for i = 0, 15 do
    lines[#lines + 1] = "    n" .. i .. " = sbox[s" .. shift[i + 1] .. "];"
  end
  for i = 0, 15 do
    lines[#lines + 1] = "    output[base + " .. i .. "] = n" .. i .. " ^ rk[160 + " .. i .. "];"
  end
  lines[#lines + 1] = "  }"
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n")
end

local function append_key_expand(lines)
  lines[#lines + 1] = "  for (i = 0; i < 16; i = i + 1) {"
  lines[#lines + 1] = "    rk[i] = key[i];"
  lines[#lines + 1] = "  }"
  lines[#lines + 1] = "  bytes = 16;"
  lines[#lines + 1] = "  for (r = 0; r < 10; r = r + 1) {"
  lines[#lines + 1] = "    t0 = sbox[rk[bytes - 3]] ^ rcon[r];"
  lines[#lines + 1] = "    t1 = sbox[rk[bytes - 2]];"
  lines[#lines + 1] = "    t2 = sbox[rk[bytes - 1]];"
  lines[#lines + 1] = "    t3 = sbox[rk[bytes - 4]];"
  lines[#lines + 1] = "    rk[bytes] = rk[bytes - 16] ^ t0; bytes = bytes + 1;"
  lines[#lines + 1] = "    rk[bytes] = rk[bytes - 16] ^ t1; bytes = bytes + 1;"
  lines[#lines + 1] = "    rk[bytes] = rk[bytes - 16] ^ t2; bytes = bytes + 1;"
  lines[#lines + 1] = "    rk[bytes] = rk[bytes - 16] ^ t3; bytes = bytes + 1;"
  lines[#lines + 1] = "    for (i = 0; i < 12; i = i + 1) {"
  lines[#lines + 1] = "      rk[bytes] = rk[bytes - 16] ^ rk[bytes - 4];"
  lines[#lines + 1] = "      bytes = bytes + 1;"
  lines[#lines + 1] = "    }"
  lines[#lines + 1] = "  }"
end

local function build_aes_dec_src()
  local lines = {
    "void aes128_ecb_decrypt(uint8_t *input, uint8_t *output, int32_t blocks, uint8_t *key, uint8_t *sbox, uint8_t *inv_sbox, uint8_t *rcon, uint8_t *rk) {",
    "  int32_t i = 0;",
    "  int32_t r = 0;",
    "  int32_t blk = 0;",
    "  int32_t base = 0;",
    "  int32_t bytes = 0;",
    "  uint32_t t0 = 0;",
    "  uint32_t t1 = 0;",
    "  uint32_t t2 = 0;",
    "  uint32_t t3 = 0;",
  }
  for _, prefix in ipairs({ "s", "n" }) do
    for i = 0, 15 do
      lines[#lines + 1] = "  uint32_t " .. prefix .. i .. " = 0;"
    end
  end
  for i = 0, 3 do
    lines[#lines + 1] = "  uint32_t x" .. i .. " = 0;"
    lines[#lines + 1] = "  uint32_t y" .. i .. " = 0;"
    lines[#lines + 1] = "  uint32_t z" .. i .. " = 0;"
    lines[#lines + 1] = "  uint32_t w" .. i .. " = 0;"
  end
  append_key_expand(lines)
  lines[#lines + 1] = "  for (blk = 0; blk < blocks; blk = blk + 1) {"
  lines[#lines + 1] = "    base = blk * 16;"
  for i = 0, 15 do
    lines[#lines + 1] = "    s" .. i .. " = input[base + " .. i .. "] ^ rk[160 + " .. i .. "];"
  end
  lines[#lines + 1] = "    for (r = 9; r > 0; r = r - 1) {"
  local inv_shift = { 0, 13, 10, 7, 4, 1, 14, 11, 8, 5, 2, 15, 12, 9, 6, 3 }
  for i = 0, 15 do
    lines[#lines + 1] = "      n" .. i .. " = inv_sbox[s" .. inv_shift[i + 1] .. "] ^ rk[(r * 16) + " .. i .. "];"
  end
  local function xtime(v)
    return "((" .. v .. " << 1) ^ ((0 - ((" .. v .. " >> 7) & 1)) & 27)) & 255"
  end
  local function inv_mix_col(offset)
    for i = 0, 3 do
      lines[#lines + 1] = "      x" .. i .. " = n" .. (offset + i) .. ";"
      lines[#lines + 1] = "      y" .. i .. " = " .. xtime("x" .. i) .. ";"
      lines[#lines + 1] = "      z" .. i .. " = " .. xtime("y" .. i) .. ";"
      lines[#lines + 1] = "      w" .. i .. " = " .. xtime("z" .. i) .. ";"
    end
    lines[#lines + 1] = "      s" .. offset .. " = (w0 ^ z0 ^ y0) ^ (w1 ^ y1 ^ x1) ^ (w2 ^ z2 ^ x2) ^ (w3 ^ x3);"
    lines[#lines + 1] = "      s" .. (offset + 1) .. " = (w0 ^ x0) ^ (w1 ^ z1 ^ y1) ^ (w2 ^ y2 ^ x2) ^ (w3 ^ z3 ^ x3);"
    lines[#lines + 1] = "      s" .. (offset + 2) .. " = (w0 ^ z0 ^ x0) ^ (w1 ^ x1) ^ (w2 ^ z2 ^ y2) ^ (w3 ^ y3 ^ x3);"
    lines[#lines + 1] = "      s" .. (offset + 3) .. " = (w0 ^ y0 ^ x0) ^ (w1 ^ z1 ^ x1) ^ (w2 ^ x2) ^ (w3 ^ z3 ^ y3);"
  end
  inv_mix_col(0)
  inv_mix_col(4)
  inv_mix_col(8)
  inv_mix_col(12)
  lines[#lines + 1] = "    }"
  for i = 0, 15 do
    lines[#lines + 1] = "    output[base + " .. i .. "] = inv_sbox[s" .. inv_shift[i + 1] .. "] ^ rk[" .. i .. "];"
  end
  lines[#lines + 1] = "  }"
  lines[#lines + 1] = "}"
  return table.concat(lines, "\n")
end

local function ensure_viper_api()
  if not viper or not viper.compile_c or not viper.buf then
    return false, "viper api missing"
  end
  if not state.bulk_api_checked then
    local probe = viper.buf(1)
    if not probe.from_string or not probe.to_string or not probe.from_table or not probe.to_table then
      return false, "viper buffer bulk api missing"
    end
    state.bulk_api_checked = true
  end
  return true, nil
end

local function compile_viper_once(field, build_fn, label)
  if state[field] then
    return true, nil
  end
  local ok, fn = pcall(function()
    return viper.compile_c(build_fn(), { bounds = false })
  end)
  if not ok or not fn then
    return false, "compile " .. label .. " failed: " .. tostring(fn)
  end
  state[field] = fn
  return true, nil
end

local function table_to_buf(src, bytes)
  local buf = viper.buf(bytes or #src)
  buf:from_table(src, "u8")
  return buf
end

local function ensure_aes_tables(need_inv_sbox)
  if not state.sbox then
    state.sbox = table_to_buf(AES_SBOX, 256)
  end
  if need_inv_sbox and not state.inv_sbox then
    state.inv_sbox = table_to_buf(AES_INV_SBOX, 256)
  end
  if not state.rcon then
    state.rcon = table_to_buf(AES_RCON, 16)
  end
  return true, nil
end

local function ensure_md5()
  local ok, err = ensure_viper_api()
  if not ok then
    return false, err
  end
  return compile_viper_once("md5_fn", build_md5_src, "md5")
end

local function ensure_aes_enc()
  local ok, err = ensure_viper_api()
  if not ok then
    return false, err
  end
  ok, err = compile_viper_once("aes_fn", build_aes_src, "aes")
  if not ok then
    return false, err
  end
  return ensure_aes_tables(false)
end

local function ensure_aes_dec()
  local ok, err = ensure_viper_api()
  if not ok then
    return false, err
  end
  ok, err = compile_viper_once("aes_dec_fn", build_aes_dec_src, "aes decrypt")
  if not ok then
    return false, err
  end
  return ensure_aes_tables(true)
end

local function md5_state_buf()
  if not state.md5_fn then
    return nil
  end
  if not state.md5_st then
    state.md5_st = viper.buf(16)
  end
  state.md5_st:set32(0, 0x67452301)
  state.md5_st:set32(1, 0xefcdab89)
  state.md5_st:set32(2, 0x98badcfe)
  state.md5_st:set32(3, 0x10325476)
  return state.md5_st
end

local function aes_key_buf(key16)
  if not state.key_buf then
    state.key_buf = viper.buf(16)
  end
  write_string_to_buf(state.key_buf, 0, key16)
  return state.key_buf
end

local function aes_rk_buf()
  if not state.rk then
    state.rk = viper.buf(176)
  end
  return state.rk
end

local function aes_encrypt_buf(in_buf, len, key16)
  local out_buf = viper.buf(len)
  state.aes_fn(in_buf, out_buf, math.floor(len / 16), aes_key_buf(key16), state.sbox, state.rcon, aes_rk_buf())
  return buf_to_string(out_buf, len), nil
end

local function aes_decrypt_buf(in_buf, len, key16)
  local out_buf = viper.buf(len)
  state.aes_dec_fn(in_buf, out_buf, math.floor(len / 16), aes_key_buf(key16), state.sbox, state.inv_sbox, state.rcon, aes_rk_buf())
  return buf_to_string(out_buf, len), nil
end

local function md5_hex(raw)
  raw = tostring(raw or "")
  local ok, err = ensure_md5()
  if not ok then
    return nil, err
  end
  local buf, total = md5_message_buf(raw)
  local st = md5_state_buf()
  if not st then
    return nil, "md5 state missing"
  end
  state.md5_fn(buf, math.floor(total / 64), st)
  return buf_to_hex(st, 16), nil
end

local function aes_128_ecb_encrypt(raw, key16)
  raw = tostring(raw or "")
  key16 = tostring(key16 or "")
  if #key16 ~= 16 then
    return nil, "aes key must be 16 bytes"
  end
  if (#raw % 16) ~= 0 then
    return nil, "aes input must be 16-byte aligned"
  end
  local ok, err = ensure_aes_enc()
  if not ok then
    return nil, err
  end
  if #raw == 0 then
    return "", nil
  end
  local in_buf = string_to_buf(raw)
  return aes_encrypt_buf(in_buf, #raw, key16)
end

local function aes_128_ecb_pkcs7_encrypt(raw, key16)
  raw = tostring(raw or "")
  key16 = tostring(key16 or "")
  if #key16 ~= 16 then
    return nil, "aes key must be 16 bytes"
  end
  local ok, err = ensure_aes_enc()
  if not ok then
    return nil, err
  end
  local in_buf, total = pkcs7_message_buf(raw)
  return aes_encrypt_buf(in_buf, total, key16)
end

local function aes_128_ecb_decrypt(raw, key16)
  raw = tostring(raw or "")
  key16 = tostring(key16 or "")
  if #key16 ~= 16 then
    return nil, "aes key must be 16 bytes"
  end
  if (#raw % 16) ~= 0 then
    return nil, "aes input must be 16-byte aligned"
  end
  local ok, err = ensure_aes_dec()
  if not ok then
    return nil, err
  end
  if #raw == 0 then
    return "", nil
  end
  local in_buf = string_to_buf(raw)
  return aes_decrypt_buf(in_buf, #raw, key16)
end

local function aes_128_ecb_pkcs7_decrypt(raw, key16)
  local plain, err = aes_128_ecb_decrypt(raw, key16)
  if not plain then
    return nil, err
  end
  if #plain == 0 then
    return nil, "empty aes plaintext"
  end
  local pad = plain:byte(#plain) or 0
  if pad < 1 or pad > 16 or pad > #plain then
    return nil, "bad pkcs7 padding"
  end
  for i = #plain - pad + 1, #plain do
    if plain:byte(i) ~= pad then
      return nil, "bad pkcs7 padding"
    end
  end
  return plain:sub(1, #plain - pad), nil
end

local function parse_aes_key(value)
  value = tostring(value or ""):gsub("%s+", "")
  if value:match("^[0-9a-fA-F]+$") and #value == 32 then
    return hex_to_bytes(value)
  end
  local decoded, err = base64_decode(value)
  if not decoded then
    return nil, err
  end
  if #decoded == 16 then
    return decoded, nil
  end
  if #decoded == 32 and decoded:match("^[0-9a-fA-F]+$") then
    return hex_to_bytes(decoded)
  end
  return nil, "bad aes key"
end

local function random_bytes(n)
  n = tonumber(n) or 0
  local out = {}
  for i = 1, n do
    out[i] = string.char(math.random(0, 255))
  end
  return table.concat(out)
end

local function random_hex(n)
  return bytes_to_hex(random_bytes(n))
end

local function self_test()
  local md5_empty, err = md5_hex("")
  if not md5_empty then
    return false, err
  end
  if md5_empty ~= "d41d8cd98f00b204e9800998ecf8427e" then
    return false, "md5 empty mismatch: " .. tostring(md5_empty)
  end
  local md5_abc = md5_hex("abc")
  if md5_abc ~= "900150983cd24fb0d6963f7d28e17f72" then
    return false, "md5 abc mismatch: " .. tostring(md5_abc)
  end
  local key = assert(hex_to_bytes("000102030405060708090a0b0c0d0e0f"))
  local plain = assert(hex_to_bytes("00112233445566778899aabbccddeeff"))
  local cipher = aes_128_ecb_encrypt(plain, key)
  if bytes_to_hex(cipher or "") ~= "69c4e0d86a7b0430d8cdb78070b4c55a" then
    return false, "aes vector mismatch: " .. bytes_to_hex(cipher or "")
  end
  local back = aes_128_ecb_decrypt(cipher, key)
  if bytes_to_hex(back or "") ~= "00112233445566778899aabbccddeeff" then
    return false, "aes decrypt vector mismatch: " .. bytes_to_hex(back or "")
  end
  local padded_cipher = aes_128_ecb_pkcs7_encrypt("hello", key)
  local padded_back = padded_cipher and aes_128_ecb_pkcs7_decrypt(padded_cipher, key) or nil
  if padded_back ~= "hello" then
    return false, "aes pkcs7 roundtrip mismatch"
  end
  return true, "ok"
end

function M.init(APP)
  M.APP = APP
  math.randomseed((APP.core.now_ms() or 0) + math.random(1, 9999))
  APP.wechat_crypto = {
    md5_hex = md5_hex,
    aes_128_ecb_encrypt = aes_128_ecb_encrypt,
    aes_128_ecb_pkcs7_encrypt = aes_128_ecb_pkcs7_encrypt,
    aes_128_ecb_decrypt = aes_128_ecb_decrypt,
    aes_128_ecb_pkcs7_decrypt = aes_128_ecb_pkcs7_decrypt,
    base64_encode = base64_encode,
    base64_decode = base64_decode,
    bytes_to_hex = bytes_to_hex,
    hex_to_bytes = hex_to_bytes,
    parse_aes_key = parse_aes_key,
    random_bytes = random_bytes,
    random_hex = random_hex,
    self_test = self_test,
  }
end

return M
