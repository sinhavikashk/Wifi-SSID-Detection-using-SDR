# Test recordings for the OFDM receiver

The 7 `dot11a_*.dat` files in this folder are used by the self-test of the 802.11a/g receiver.
Run it with `wifi_rx_ref` (no arguments). It must find **121 frames, all with a correct CRC-32**.

## Where the files come from

- Source: the **OpenOFDM** project, <https://github.com/jhshi/openofdm>, folder `testing_inputs/conducted/`.
- The files are copied **without any change**.
- License: **Apache License 2.0**. A copy of the license is in [`LICENSE-APACHE-2.0.txt`](LICENSE-APACHE-2.0.txt).

## What is inside

- Raw complex samples at **20 MS/s**, stored as 16-bit signed integers (little-endian), I and Q interleaved
  (I, Q, I, Q, ...). Read one with `x = wifi_rx_ref('load_dat', 'path/to/file.dat');`.
- Each file holds real 802.11a frames, mainly at the data rate in its name (6, 9, 12, 18, 24, 36 or 48 Mbps):
  QoS data frames between `e8:de:27:90:6e:42` and `e4:90:7e:15:2a:16` (the addresses in the file names),
  plus acknowledgements and two probe responses.
