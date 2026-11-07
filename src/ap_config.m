function cfg = ap_config()
% AP_CONFIG  The few numbers you may want to change for RSSI / distance / gain. Edit here only.
%
%   --- RSSI and distance ---
%   CAL_DB            dB added to (power in dBFS - RX gain) to turn it into dBm.
%                     0 = uncalibrated. Calibrate once (README.md, "Calibrate the signal strength")
%                     so the dBm numbers match a phone Wi-Fi analyzer app.
%   TX_EIRP_DBM       Transmit power assumed for every access point.
%                     0 dBm = same assumption the Wi-Fi analyzer app makes (gives "app-style"
%                     distances). A real AP sends about 15-23 dBm, so the TRUE distance is larger.
%   PATH_EXP          Path-loss exponent n. 2 = free space (open air). Indoors / through walls
%                     use 2.5 - 3.5 (distance comes out smaller for the same RSSI).
%   GAIN_DB_FALLBACK  RX gain used only if a .mat file does not contain gain_db.
%
%   --- automatic gain per channel (hunt_ssids_plus) ---
%   GAIN_START_DB     first capture on every channel uses this gain
%   GAIN_STEP_DB      if the ADC clips -> capture again with this much LESS gain;
%                     if the capture is only noise -> capture again with this much MORE gain
%   GAIN_MIN_DB / GAIN_MAX_DB   limits for the automatic gain (the Pluto allows at most 62 dB at 5 GHz)
%   CLIP_FRAC         fraction of clipped samples above which a capture counts as clipped
%   WEAK_PEAK         peak I/Q (0..1) below which a capture counts as "nothing but noise"
%   MAX_CAPTURES      most captures per channel (each one takes several seconds)
  cfg.CAL_DB           = 0;
  cfg.TX_EIRP_DBM      = 0;
  cfg.PATH_EXP         = 2;
  cfg.GAIN_DB_FALLBACK = 30;

  cfg.GAIN_START_DB    = 45;
  cfg.GAIN_STEP_DB     = 20;
  cfg.GAIN_MIN_DB      = 5;
  cfg.GAIN_MAX_DB      = 60;
  cfg.CLIP_FRAC        = 1e-5;
  cfg.WEAK_PEAK        = 0.05;
  cfg.MAX_CAPTURES     = 3;
end