function d = rssi_to_distance(rssi_dbm, freq_mhz, tx_eirp_dbm, n)
% RSSI_TO_DISTANCE  Distance (metres) from received power, using the log-distance path-loss model.
%
%   d = rssi_to_distance(rssi_dbm, freq_mhz)                  % defaults from ap_config.m
%   d = rssi_to_distance(rssi_dbm, freq_mhz, tx_eirp_dbm, n)
%
%   Path loss          PL  = tx_eirp_dbm - rssi_dbm                     (dB)
%   Loss at 1 metre    PL1 = 20*log10(freq_mhz) - 27.55                 (free-space formula)
%   Distance           d   = 10 ^ ((PL - PL1) / (10*n))
%
%   With tx_eirp_dbm = 0 and n = 2 this is the same formula Wi-Fi analyzer apps use.
%   rssi_dbm may be a vector; freq_mhz may be a scalar or a vector of the same length.
  if nargin < 3 || isempty(tx_eirp_dbm) || nargin < 4 || isempty(n)
    cfg = ap_config();
    if nargin < 3 || isempty(tx_eirp_dbm), tx_eirp_dbm = cfg.TX_EIRP_DBM; end
    if nargin < 4 || isempty(n),           n = cfg.PATH_EXP; end
  end
  pl  = tx_eirp_dbm - rssi_dbm;
  pl1 = 20*log10(freq_mhz) - 27.55;
  d = 10 .^ ((pl - pl1) ./ (10*n));
end
