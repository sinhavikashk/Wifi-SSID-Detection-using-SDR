function varargout = wifi_rx_ref(name, varargin)
% WIFI_RX_REF  802.11a/g (legacy OFDM, 20 MHz) receiver. MATLAB and Octave, toolbox-free.
%
%   wifi_rx_ref                          run the self-test (unit checks + 121 real frames)
%   x       = wifi_rx_ref('load_dat', path)          read an int16 I/Q .dat capture
%   results = wifi_rx_ref('decode_capture', x)       decode every OFDM frame in a capture
%   m       = wifi_rx_ref('parse_mgmt', psdu)        parse a beacon / probe-response
%   s       = wifi_rx_ref('ssid_text', m.ssid)       SSID bytes -> text
%
% Everything lives in this one file as local functions; the switch below is the only
% public door. Uses only fprintf/fft/etc. that exist in both MATLAB and Octave.

  if nargin == 0
    selftest();
    return;
  end
  switch name
    case 'load_dat'
      [varargout{1:max(nargout,1)}] = load_dat(varargin{:});
    case 'decode_capture'
      [varargout{1:max(nargout,1)}] = decode_capture(varargin{:});
    case 'parse_mgmt'
      [varargout{1:max(nargout,1)}] = parse_mgmt(varargin{:});
    case 'ssid_text'
      [varargout{1:max(nargout,1)}] = ssid_text(varargin{:});
    otherwise
      error('wifi_rx_ref:unknownCommand', 'Unknown command "%s".', name);
  end
end

% =============================================================================================
% file / small helpers
% =============================================================================================
function y = load_dat(path)
  fid = fopen(path, 'rb');
  if fid < 0, error('wifi_rx_ref:open', 'Cannot open %s', path); end
  a = fread(fid, Inf, 'int16', 0, 'ieee-le');
  fclose(fid);
  a = double(a);
  y = a(1:2:end) + 1j*a(2:2:end);
  y = reshape(y, 1, []);
end

function s = lfsr_all_ones(n)
  % 802.11 scrambler x^7+x^4+1, all-ones seed (also drives pilot polarity)
  x = ones(1,7);
  s = zeros(1,n);
  for i = 1:n
    fb = double(xor(x(7), x(4)));
    s(i) = fb;
    x = [fb, x(1:6)];
  end
end

function s = scrambler_from_first7(first7, n)
  s = zeros(1,127);
  s(1:7) = first7;
  for i = 8:127
    s(i) = double(xor(s(i-7), s(i-4)));
  end
  s = s(mod(0:n-1, 127) + 1);
end

function c = crc32_ieee(bytes)
  % standard CRC-32: poly 0xEDB88320 (reflected), init 0xFFFFFFFF, final XOR 0xFFFFFFFF
  crc = uint32(4294967295);
  poly = uint32(3988292384);
  for k = 1:numel(bytes)
    crc = bitxor(crc, uint32(bytes(k)));
    for b = 1:8
      if bitand(crc, uint32(1)) == 1
        crc = bitxor(bitshift(crc, -1), poly);
      else
        crc = bitshift(crc, -1);
      end
    end
  end
  c = bitxor(crc, uint32(4294967295));
end

function v = bits2num_msb(b)
  v = 0;
  for i = 1:numel(b), v = v*2 + b(i); end
end

% =============================================================================================
% modulation / coding building blocks
% =============================================================================================
function [pts, bits] = constellation(nbpsc)
  M = 2^nbpsc;
  pts = zeros(1, M);
  bits = zeros(M, nbpsc);
  for m = 0:M-1
    b = bitget(m, nbpsc:-1:1);          % MSB first
    bits(m+1, :) = b;
    if nbpsc == 1
      pts(m+1) = 2*b(1) - 1;            % bit 0 -> -1, bit 1 -> +1
    else
      h = nbpsc/2;
      ii = bits2num_msb(b(1:h));
      qq = bits2num_msb(b(h+1:end));
      pts(m+1) = pam_level(h, ii) + 1j*pam_level(h, qq);
    end
  end
  switch nbpsc
    case 1, kmod = 1;
    case 2, kmod = 1/sqrt(2);
    case 4, kmod = 1/sqrt(10);
    case 6, kmod = 1/sqrt(42);
  end
  pts = pts * kmod;
end

function a = pam_level(h, idx)
  % Gray-coded PAM levels used by 802.11 (idx = integer value of the h bits, MSB first)
  switch h
    case 1, tab = [-1 1];
    case 2, tab = [-3 -1 3 1];
    case 3, tab = [-7 -5 -1 -3 7 5 1 3];
  end
  a = tab(idx+1);
end

function [pts, bits] = constellation_cached(nbpsc)
  persistent C
  if isempty(C), C = cell(1, 6); end
  if isempty(C{nbpsc})
    [p, b] = constellation(nbpsc);
    C{nbpsc} = {p, b};
  end
  pts = C{nbpsc}{1}; bits = C{nbpsc}{2};
end

function llr = soft_demap(y, w, nbpsc)
  % max-log LLR; positive => bit 0 more likely.  y: equalised symbols, w: reliability weights
  [pts, bits] = constellation_cached(nbpsc);
  d = abs(y(:) - pts).^2;                         % (48 x M)
  llr = zeros(numel(y), nbpsc);
  for b = 1:nbpsc
    is1 = bits(:,b) == 1;
    d0 = min(d(:, ~is1), [], 2);
    d1 = min(d(:, is1), [], 2);
    llr(:,b) = (d1 - d0) .* w(:);
  end
  llr = reshape(llr.', 1, []);
end

function j = interleave_perm(ncbps, nbpsc)
  % j(k) (1-based) = transmitted position of coded bit k.  Receiver gathers: deint = llr(j)
  s = max(floor(nbpsc/2), 1);
  k = 0:ncbps-1;
  i = (ncbps/16) * mod(k,16) + floor(k/16);
  j = s*floor(i/s) + mod(i + ncbps - floor(16*i/ncbps), s);
  j = j + 1;
end

function out = conv_encode(bits)
  tapsA = [0 2 3 5 6]; tapsB = [0 1 2 3 6];
  u = [zeros(1,6), bits];
  n = numel(bits);
  A = zeros(1,n); B = zeros(1,n);
  for d = tapsA
    A = double(xor(A, u(6-d+1 : 6-d+n)));
  end
  for d = tapsB
    B = double(xor(B, u(6-d+1 : 6-d+n)));
  end
  out = zeros(1, 2*n);
  out(1:2:end) = A;
  out(2:2:end) = B;
end

function pat = punct_pattern(cr)
  if isequal(cr, [1 2])
    pat = [1 1];
  elseif isequal(cr, [2 3])
    pat = [1 1 1 0];
  else
    pat = [1 1 1 0 0 1];                          % 3/4
  end
end

function mother = depuncture(llr, cr)
  pat = punct_pattern(cr);
  ng = ceil(numel(llr) / sum(pat));
  keep = logical(repmat(pat, 1, ng));
  mother = zeros(1, numel(keep));
  mother(keep) = llr;
end

function [a0, b0, a1, b1, p0, p1] = trellis_tables()
  % branch signs for the K=7 code, computed once
  persistent T
  if isempty(T)
    tapsA = [0 2 3 5 6]; tapsB = [0 1 2 3 6];
    maskA = sum(2.^tapsA); maskB = sum(2.^tapsB);
    states = 0:63;
    outA = zeros(64,2); outB = zeros(64,2);
    for st = 0:63
      for u = 0:1
        v = bitor(u, bitshift(st,1));
        outA(st+1,u+1) = mod(sum(bitget(bitand(v,maskA), 1:8)), 2);
        outB(st+1,u+1) = mod(sum(bitget(bitand(v,maskB), 1:8)), 2);
      end
    end
    T.p0 = floor(states/2); T.p1 = T.p0 + 32; u = mod(states,2);
    T.a0 = 1 - 2*outA(sub2ind([64,2], T.p0+1, u+1)); T.b0 = 1 - 2*outB(sub2ind([64,2], T.p0+1, u+1));
    T.a1 = 1 - 2*outA(sub2ind([64,2], T.p1+1, u+1)); T.b1 = 1 - 2*outB(sub2ind([64,2], T.p1+1, u+1));
  end
  a0 = T.a0; b0 = T.b0; a1 = T.a1; b1 = T.b1; p0 = T.p0; p1 = T.p1;
end

function bits = viterbi_decode(llr)
  % soft-decision Viterbi, K=7, g0=133 g1=171 (octal), terminated in state 0
  [a0, b0, a1, b1, p0, p1] = trellis_tables();
  T = floor(numel(llr)/2);
  la = llr(1:2:end); lb = llr(2:2:end);
  pm = -1e18*ones(1,64); pm(1) = 0;
  dec = zeros(T, 64);
  for t = 1:T
    m0 = pm(p0+1) + a0*la(t) + b0*lb(t);
    m1 = pm(p1+1) + a1*la(t) + b1*lb(t);
    sel = m1 > m0;
    dec(t,:) = sel;
    pm = m0;
    pm(sel) = m1(sel);
  end
  st = 0;
  bits = zeros(1,T);
  for t = T:-1:1
    bits(t) = mod(st,2);
    st = floor(st/2) + 32*dec(t, st+1);
  end
end

% =============================================================================================
% OFDM front end
% =============================================================================================
function G = ofdm_gen()
  G.PILOT_K = [-21 -7 7 21];
  G.PILOT_BASE = [1 1 1 -1];
  used = setdiff(-26:26, 0);
  G.USED_K = used;
  G.DATA_K = setdiff(used, G.PILOT_K);
  Lseq = [1 1 -1 -1 1 1 -1 1 -1 1 1 1 1 1 1 -1 -1 1 1 -1 1 -1 1 1 1 1, 0, ...
          1 -1 -1 1 1 -1 1 -1 1 -1 -1 -1 -1 -1 1 1 -1 -1 1 -1 1 -1 1 1 1 1];
  X = zeros(1,64);
  for k = -26:26
    X(mod(k,64)+1) = Lseq(k+27);
  end
  G.LTF_SYM = ifft(X);
  ks = [-24 -20 -16 -12 -8 -4 4 8 12 16 20 24];
  sg = [  1  -1   1  -1 -1  1 -1 -1  1  1  1  1];
  Xs = zeros(1,64);
  Xs(mod(ks,64)+1) = sg*(1+1j)*sqrt(13/6);
  G.STF_SYM = ifft(Xs);
  G.LTF_FREQ = Lseq(G.USED_K + 27);
  G.PN = 1 - 2*lfsr_all_ones(127);
end

function cands = detect_candidates(x)
  % delay-and-correlate (lag 16) plateau detector on the repeating short training field
  lag = 16; win = 48; thr = 0.5; min_run = 40; max_gap = 8;
  cands = {};
  if numel(x) < lag + win + 400, return; end
  prod_ = x(1:end-lag) .* conj(x(lag+1:end));
  pw = abs(x(lag+1:end)).^2;
  cs = cumsum([0, prod_]);
  cp = cumsum([0, pw]);
  P = cs(win+1:end) - cs(1:end-win);
  R = cp(win+1:end) - cp(1:end-win);
  hot = (abs(P) ./ (R + 1e-12)) > thr;
  dh = diff([0, double(hot), 0]);
  rs = find(dh == 1);                              % run starts
  re = find(dh == -1) - 1;                         % run ends
  if isempty(rs), return; end
  % merge runs separated by a gap of at most max_gap non-hot samples
  new_run = [true, (rs(2:end) - re(1:end-1)) > max_gap];
  starts = rs(new_run);
  ends = re([new_run(2:end), true]);
  keep = (ends - starts + 1) >= min_run;
  starts = starts(keep); ends = ends(keep);
  cands = cell(1, numel(starts));
  for i = 1:numel(starts)
    cands{i} = struct('s', starts(i), 'e', ends(i));
  end
end

function bursts = energy_bursts(x, dc)
  % Energy bursts for the OFDM decoder: rows [first_sample last_sample].
  % Blocks of 100 samples (5 us); a block is "active" if it is >2.5x the noise floor (1st
  % percentile of block powers); gaps up to 4 blocks are bridged; bursts under 30 us are dropped.
  block = 100; thr = 2.5; min_blocks = 6; max_gap = 4;
  nb = floor(numel(x) / block);
  bursts = zeros(0, 2);
  if nb < 10, return; end
  P = zeros(1, nb);
  step = 40000;
  for c0 = 1:step:nb
    c1 = min(nb, c0 + step - 1);
    seg = double(x((c0-1)*block + 1 : c1*block)) - dc;
    P(c0:c1) = mean(reshape(abs(seg).^2, block, c1 - c0 + 1), 1);
  end
  sP = sort(P);
  % noise floor = 1st percentile of block powers: right for a noise-dominated Pluto capture
  % (noise blocks everywhere) AND for a dense capture that is mostly frames (a few % idle).
  % The max() guards against all-zero dropout blocks pulling the floor to 0.
  floorP = max(sP(max(1, round(0.01 * nb))), 1e-3 * median(P));
  idx = find(P > thr * floorP);
  if isempty(idx), return; end
  gaps = diff(idx) > max_gap + 1;
  rs = idx([true, gaps]);
  re = idx([gaps, true]);
  keep = (re - rs + 1) >= min_blocks;
  rs = rs(keep); re = re(keep);
  bursts = [(rs(:) - 1)*block + 1, re(:)*block];
end

function est = sync_and_estimate(x, cand, G)
  FS = 20e6; DELTA = 4; N = numel(x);
  s = cand.s; e = cand.e;
  est = [];
  a = s + 8; b = min([e, s + 96, N - 16]);
  if b < a, return; end
  Pc = sum(x(a:b) .* conj(x(a+16:b+16)));
  cfo_c = -angle(Pc) * FS / (2*pi*16);
  n = 0:N-1;
  xc = x .* exp(-2j*pi*cfo_c*n/FS);
  lo = max(1, s + 192 - 80);
  hi = min(N-128, s + 192 + 80);
  if hi <= lo, return; end
  Tm = conj(G.LTF_SYM);
  L = hi - lo + 1 + 64;
  if lo + L - 1 + 63 > N, return; end
  corr = zeros(1, L);
  for i = 1:L
    corr(i) = abs(Tm * xc(lo+i-1 : lo+i+62).');
  end
  corr2 = corr(1:hi-lo+1) + corr(65:64+hi-lo+1);   % pair metric: LTF symbol 1 + symbol 2
  [pk, k] = max(corr2);
  t0 = lo + k - 1;
  if pk < 6 * 2 * median(corr), return; end
  y1 = xc(t0:t0+63);
  y2 = xc(t0+64:t0+127);
  cfo_f = angle(sum(conj(y1).*y2)) * FS / (2*pi*64);
  cfo = cfo_c + cfo_f;
  xc = x .* exp(-2j*pi*cfo*n/FS);
  Y1f = fft(xc(t0-DELTA : t0-DELTA+63));
  Y2f = fft(xc(t0+64-DELTA : t0+127-DELTA));
  idxU = mod(G.USED_K,64) + 1;
  Y1 = Y1f(idxU); Y2 = Y2f(idxU);
  H = (Y1+Y2)/2 ./ G.LTF_FREQ;
  sigp = mean(abs((Y1+Y2)/2).^2);
  nv = mean(abs(Y1-Y2).^2)/2;
  snr = 10*log10(max(sigp - nv/2, 1e-12) / max(nv, 1e-12));
  est = struct('t0', t0, 'cfo', cfo, 'xc', xc, 'H', H, 'snr_db', snr);
end

function [eq, w] = ofdm_symbol(xc, start, H, sym_idx, G)
  Y = fft(xc(start:start+63));
  Hfull = zeros(1,64);
  Hfull(mod(G.USED_K,64)+1) = H;
  idxD = mod(G.DATA_K,64) + 1;
  idxP = mod(G.PILOT_K,64) + 1;
  Yd = Y(idxD); Hd = Hfull(idxD);
  Yp = Y(idxP); Hp = Hfull(idxP);
  pil_exp = G.PILOT_BASE * G.PN(mod(sym_idx,127)+1);
  z = sum(conj(pil_exp) .* (Yp ./ Hp) .* abs(Hp).^2);
  theta = angle(z);
  eq = (Yd ./ Hd) * exp(-1j*theta);
  w = abs(Hd).^2;
end

function sig = decode_signal(xc, t0, H, G)
  DELTA = 4;
  sig = [];
  [eq, w] = ofdm_symbol(xc, t0 + 128 + 16 - DELTA, H, 0, G);
  llr = soft_demap(eq, w/mean(w), 1);
  deint = llr(interleave_perm(48,1));                 % GATHER (not scatter)
  bits = viterbi_decode(deint);
  rateb = bits(1:4);
  reserved = bits(5);
  length_ = sum(bits(6:17) .* 2.^(0:11));
  parity_ok = mod(sum(bits(1:18)),2) == 0;
  tail_ok = ~any(bits(19:24));
  key = sprintf('%d%d%d%d', rateb(1), rateb(2), rateb(3), rateb(4));
  switch key
    case '1101', mbps = 6;  nbpsc = 1; cr = [1 2];
    case '1111', mbps = 9;  nbpsc = 1; cr = [3 4];
    case '0101', mbps = 12; nbpsc = 2; cr = [1 2];
    case '0111', mbps = 18; nbpsc = 2; cr = [3 4];
    case '1001', mbps = 24; nbpsc = 4; cr = [1 2];
    case '1011', mbps = 36; nbpsc = 4; cr = [3 4];
    case '0001', mbps = 48; nbpsc = 6; cr = [2 3];
    case '0011', mbps = 54; nbpsc = 6; cr = [3 4];
    otherwise,   return;
  end
  if ~parity_ok || ~tail_ok || reserved ~= 0 || length_ < 14 || length_ > 2400, return; end
  sig = struct('mbps', mbps, 'nbpsc', nbpsc, 'cr', cr, 'length', length_);
end

function dat = decode_data(xc, t0, H, sig, G)
  DELTA = 4;
  dat = [];
  ncbps = 48*sig.nbpsc;
  ndbps = ncbps*sig.cr(1)/sig.cr(2);
  ninfo = 16 + 8*sig.length + 6;
  nsym = ceil(ninfo/ndbps);
  if t0 + 128 + 80*(nsym+1) + 16 > numel(xc), return; end
  perm = interleave_perm(ncbps, sig.nbpsc);
  llrs = zeros(1, nsym*ncbps);
  for i = 1:nsym
    start = t0 + 128 + 80*i + 16 - DELTA;
    [eq, w] = ofdm_symbol(xc, start, H, i, G);
    l = soft_demap(eq, w/mean(w), sig.nbpsc);
    llrs((i-1)*ncbps+1 : i*ncbps) = l(perm);          % GATHER (not scatter)
  end
  mother = depuncture(llrs, sig.cr);
  mother = mother(1:2*ninfo);
  bits = viterbi_decode(mother);
  scr = scrambler_from_first7(bits(1:7), ninfo);
  data = double(xor(bits, scr));
  psdu_bits = data(17:16+8*sig.length);
  psdu = zeros(1, sig.length, 'uint8');
  for i = 1:sig.length
    psdu(i) = uint8(sum(psdu_bits((i-1)*8+1 : i*8) .* 2.^(0:7)));   % LSB first
  end
  dat = struct('psdu', psdu, 'service_ok', ~any(data(1:16)), 'nsym', nsym);
end

function ok = fcs_ok(psdu)
  ok = false;
  if numel(psdu) < 5, return; end
  t = double(psdu(end-3:end));
  want = t(1) + t(2)*256 + t(3)*65536 + t(4)*16777216;
  got = double(crc32_ieee(psdu(1:end-4)));
  ok = (got == want);
end

function nsym = frame_nsym(sig)
  ncbps = 48*sig.nbpsc;
  ndbps = ncbps*sig.cr(1)/sig.cr(2);
  nsym = ceil((16 + 8*sig.length + 6)/ndbps);
end

function results = decode_capture(x)
  % Full pipeline over one capture. Only the energy bursts are examined (noise is never
  % searched for preambles), each burst on its own short segment, so a 30 M-sample capture with
  % spurs or coloured noise costs about the same as a clean one. Returns a cell array of structs:
  %   t0 (absolute sample index of the first long-training symbol), cfo, snr_db, mbps,
  %   length, fcs_ok, psdu
  G = ofdm_gen();
  x = reshape(x, 1, []);
  N = numel(x);
  dc = mean(double(x(1:min(N, 4000000))));            % LO leakage / DC offset
  bursts = energy_bursts(x, dc);
  results = {};
  for bi = 1:size(bursts, 1)
    lo = max(1, bursts(bi,1) - 400);
    hi = min(N, bursts(bi,2) + 400);
    xb = double(x(lo:hi)) - dc;
    Nb = numel(xb);
    cands = detect_candidates(xb);
    used_until = -1;
    for ci = 1:numel(cands)
      cand = cands{ci};
      if cand.s < used_until, continue; end
      a = max(1, cand.s - 100);
      loc = struct('s', cand.s - a + 1, 'e', cand.e - a + 1);
      seg = xb(a : min(Nb, cand.s + 900));               % short segment: enough for SIGNAL
      est = sync_and_estimate(seg, loc, G);
      if isempty(est), continue; end
      sig = decode_signal(est.xc, est.t0, est.H, G);
      if isempty(sig), continue; end
      nsym = frame_nsym(sig);
      b2 = a - 1 + est.t0 + 128 + 80*(nsym+1) + 16;      % last sample the whole frame needs
      if b2 > Nb, continue; end                          % frame is cut off by the end of the burst
      if b2 > a - 1 + numel(seg)
        seg = xb(a:b2);
        est = sync_and_estimate(seg, loc, G);
        if isempty(est), continue; end
      end
      dat = decode_data(est.xc, est.t0, est.H, sig, G);
      if isempty(dat), continue; end
      t0_abs = lo - 1 + a - 1 + est.t0;
      used_until = a - 1 + est.t0 + 128 + 80*(dat.nsym+1);
      dup = false;
      for k = 1:numel(results)
        if abs(results{k}.t0 - t0_abs) < 200, dup = true; break; end
      end
      if dup, continue; end
      results{end+1} = struct('t0', t0_abs, 'cfo', est.cfo, 'snr_db', est.snr_db, ...
                              'mbps', sig.mbps, 'length', sig.length, ...
                              'fcs_ok', fcs_ok(dat.psdu), 'psdu', dat.psdu);   %#ok<AGROW>
    end
  end
end

% =============================================================================================
% MAC layer
% =============================================================================================
function s = mac2str(b)
  b = double(b(:).');
  s = sprintf('%02x:%02x:%02x:%02x:%02x:%02x', b(1), b(2), b(3), b(4), b(5), b(6));
end

function r = parse_mgmt(psdu)
  % beacon (subtype 8) / probe response (subtype 5) parser; [] if not one of those
  r = [];
  psdu = double(psdu(:).');
  if numel(psdu) < 24 + 12 + 4, return; end
  fc0 = psdu(1); fc1 = psdu(2);
  ver = bitand(fc0, 3);
  typ = bitand(bitshift(fc0, -2), 3);
  sub = bitshift(fc0, -4);
  if ver ~= 0 || typ ~= 0 || ~(sub == 8 || sub == 5), return; end
  off = 24 + 4*(bitand(fc1, 128) ~= 0);              % HT-control present?
  body = psdu(off+1 : end-4);
  if numel(body) < 12, return; end
  r = struct();
  if sub == 8, r.subtype = 'beacon'; else r.subtype = 'probe-resp'; end
  r.addr1 = mac2str(psdu(5:10));
  r.addr2 = mac2str(psdu(11:16));
  r.bssid = mac2str(psdu(17:22));
  r.tsf = sum(body(1:8) .* 256.^(0:7));
  r.interval_tu = body(9) + 256*body(10);
  r.cap = body(11) + 256*body(12);
  r.ssid = [];
  r.channel = [];
  i = 13;
  while i + 1 <= numel(body)
    eid = body(i); ln = body(i+1);
    if i + 1 + ln > numel(body), break; end
    d = body(i+2 : i+1+ln);
    if eid == 0 && isempty(r.ssid), r.ssid = d; end
    if eid == 3 && ln == 1, r.channel = d(1); end
    i = i + 2 + ln;
  end
end

function s = ssid_text(raw)
  if isempty(raw) || all(raw == 0)
    s = '<hidden>';
  else
    s = char(raw(:).');
  end
end

% =============================================================================================
% self-test
% =============================================================================================
function selftest()
  fprintf('== unit checks ==\n');
  ok_all = true;

  s = lfsr_all_ones(16);
  t = isequal(s, [0 0 0 0 1 1 1 0 1 1 1 1 0 0 1 0]);
  fprintf('scrambler first 16 bits = %s (expect 0000111011110010)  %s\n', sprintf('%d', s), passfail(t));
  ok_all = ok_all && t;

  G = ofdm_gen();
  t = isequal(G.PN(1:8), [1 1 1 1 -1 -1 -1 1]);
  fprintf('pilot polarity p0..p7 = %s (expect 1 1 1 1 -1 -1 -1 1)  %s\n', mat2str(G.PN(1:8)), passfail(t));
  ok_all = ok_all && t;

  t = (crc32_ieee(double('123456789')) == uint32(hex2dec('cbf43926')));
  fprintf('crc32("123456789") = %08x (expect cbf43926)  %s\n', crc32_ieee(double('123456789')), passfail(t));
  ok_all = ok_all && t;

  for nb = [1 2 4 6]
    pts = constellation(nb);
    t = abs(mean(abs(pts).^2) - 1) < 1e-9;
    fprintf('nbpsc=%d average power = %.4f (expect 1)  %s\n', nb, mean(abs(pts).^2), passfail(t));
    ok_all = ok_all && t;
  end

  pairs = [48 1; 96 2; 192 4; 288 6];
  for i = 1:4
    p = interleave_perm(pairs(i,1), pairs(i,2));
    t = isequal(sort(p), 1:pairs(i,1));
    fprintf('interleaver N_CBPS=%d is a permutation  %s\n', pairs(i,1), passfail(t));
    ok_all = ok_all && t;
  end

  crs = {[1 2], [2 3], [3 4]};
  for i = 1:3
    cr = crs{i};
    info = double(rand(1,600) > 0.5);
    info(end-5:end) = 0;
    mother = conv_encode(info);
    pat = punct_pattern(cr);
    keep = logical(repmat(pat, 1, ceil(numel(mother)/numel(pat))));
    keep = keep(1:numel(mother));
    tx = mother(keep);
    llr = (1 - 2*tx)*4 + 0.7*randn(1, numel(tx));
    mm = depuncture(llr, cr);
    dec = viterbi_decode(mm(1:numel(mother)));
    nerr = sum(dec ~= info);
    t = (nerr == 0);
    fprintf('conv-code + Viterbi round trip, rate %d/%d: %d errors / 600  %s\n', cr(1), cr(2), nerr, passfail(t));
    ok_all = ok_all && t;
  end

  fprintf('\n== real-capture decode ==\n');
  here = fileparts(mfilename('fullpath'));
  cands = {fullfile(here, 'test_data'), fullfile(here, 'test_data', 'test_data'), here, ...
           fullfile(pwd, 'test_data'), fullfile(pwd, 'test_data', 'test_data'), pwd};
  d = []; folder = '';
  for ci = 1:numel(cands)
    dd = dir(fullfile(cands{ci}, 'dot11a_*.dat'));
    if ~isempty(dd)
      d = dd; folder = cands{ci};
      break;
    end
  end
  if isempty(d)
    fprintf('No dot11a_*.dat files found. Folders I looked in:\n');
    for ci = 1:numel(cands), fprintf('   %s\n', cands{ci}); end
    fprintf(['Put the 7 dot11a_*.dat files in a folder called test_data\n' ...
             'next to wifi_rx_ref.m (this file is in: %s), then run wifi_rx_ref again.\n'], here);
    return;
  end
  fprintf('using test data from: %s\n', folder);
  total = 0; okc = 0;
  shown24 = false; shown48 = false;
  for fi = 1:numel(d)
    x = load_dat(fullfile(folder, d(fi).name));
    res = decode_capture(x);
    fprintf('%-60s frames=%d\n', d(fi).name, numel(res));
    for i = 1:numel(res)
      r = res{i};
      total = total + 1;
      okc = okc + r.fcs_ok;
      if r.length == 138 && r.mbps == 24 && ~shown24
        fprintf('   24 Mbps QoS-data, first 24 bytes: %s\n', sprintf('%02x', r.psdu(1:24)));
        shown24 = true;
      end
      m = parse_mgmt(r.psdu);
      if ~isempty(m) && ~shown48
        fprintf('   %s from BSSID %s: SSID=''%s'' channel=%d\n', m.subtype, m.bssid, ssid_text(m.ssid), m.channel);
        shown48 = true;
      end
    end
  end
  fprintf('\nTOTAL frames=%d  FCS_ok=%d   (expect 121 / 121)\n', total, okc);
  if ok_all && total == 121 && okc == 121
    fprintf('SELF-TEST PASSED\n');
  else
    fprintf('SELF-TEST FAILED -- see the output above\n');
  end
end

function s = passfail(t)
  if t, s = 'ok'; else, s = 'FAIL'; end
end