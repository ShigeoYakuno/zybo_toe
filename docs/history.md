# TOE 設計履歴 (history.md)

---

## 2026-05-21 — フルTOE実装 (Phase 2)

### 背景・目的

ZYBO Z7-20 + Waveshare LAN8720 ETH Board (RMII, PMOD JC+JD) 向けに、
VHDL参考実装 (`fix-tcpip-project-main`) を SystemVerilog へ移植しつつ、
Xilinx XPM マクロ (xpm_memory_tdpram / xpm_fifo_sync / xpm_fifo_async) を使用した
フルTCPオフロードエンジン (TOE) を実装した。

---

### 参照コード

| ソース | 用途 |
|--------|------|
| `fix-tcpip-project-main/` | TCP/IP VHDL参考実装 (Altera MAX10, L.Ratchanon 氏) |
| `ebaz4205_ethernet-main/` | RMII MAC SystemVerilog実装 |
| `src/toe_top.sv` | Phase 1 トップ (RMII MAC + ARP Reply のみ) |
| `src/ping_engine.sv` | Phase 1 ARP Reply エンジン |

---

### 設計上の主要決定事項

#### クロックドメイン分離
- `clk_50`: LAN8720 内蔵 OSC → REF_CLK → T11 (MRCC_P) → IBUFG → BUFG
- `s_axi_aclk`: PS7 FCLK0 (50 MHz、clk_50 とは非同期)
- 1bit 制御信号は 2段 FF 同期化、データパスは `xpm_fifo_async` で CDC

#### TX チェックサム — 2パス方式の採用
ペイロードチェックサムを計算するためにはペイロード全体を先読みする必要があるが、
AXI-Stream はバックプレッシャが不可。そのため tx_buffer を 2回読む方式を採用:
- Pass 1 (S_CSUM_PAYLOAD): ペイロードを読みながらチェックサム累積
- S_BUILD: 最終チェックサムを確定しヘッダバッファ構築
- Pass 2 (S_SEND_HDR → S_SEND_PAYLOAD): ヘッダ送信後、再度ペイロードを読み出して送信

#### TX バッファ — 3ポインタ循環バッファ
単純な FIFO では再送時にデータが失われるため、3ポインタ方式を採用:
- `wr_ptr`: ARM が書き込んだ末尾
- `send_ptr`: 次に送信する位置 (再送時は ack_ptr にリセット)
- `ack_ptr`: ACK 済み先頭 (ここまで上書き可能)

#### TX アービタ
ARP (ICMP 応答) は TCP より優先度が高い。ARP フレームは短く稀なため、
「ARP が tvalid なら ARP を通す」単純プライオリティで実装。

#### frame_mux のファンアウト方式
MAC RX にはバックプレッシャがないため、全フレームを arp_engine / tcp_layer 両方に
同時配信し、各エンジンが EtherType・アドレスフィルタで自律的に破棄する方式を採用。

---

### 作成ファイル一覧

#### MAC サブシステム (`vivado/rtl/mac/`) — ebaz4205 からコピー

| ファイル | 備考 |
|---------|------|
| `rmii_mac.sv` | MAC トップ, USE_RMII=1 固定 |
| `mii_mac_rx.sv` | RX MAC |
| `mii_mac_tx.sv` | TX MAC |
| `rmii_to_axis.sv` | RMII→AXI-Stream |
| `axis_to_rmii.sv` | AXI-Stream→RMII |
| `prepend_preamble.sv` | プリアンブル付加 |
| `append_crc.sv` | CRC-32 付加 |
| `remove_crc.sv` | CRC-32 除去・エラーフラグ |
| `crc_mac.sv` | CRC-32 計算コア |
| `axis_mux.sv` | TX 内部 MUX |
| `simple_fifo.v` | 小型同期 FIFO (Verilog-2001) |

#### TOE サブシステム (`vivado/rtl/toe/`) — 今回新規作成

| ファイル | 実装内容 |
|---------|---------|
| `lfsr_isn.sv` | x^32+x^30+x^26+x^25+1 LFSR、seed=0xABCD1234、ISN 生成 |
| `rx_buffer.sv` | 4KB xpm_fifo_sync、RX ペイロード格納 |
| `tx_buffer.sv` | 8KB xpm_memory_tdpram、3ポインタ循環バッファ、再送対応 |
| `arp_engine.sv` | ARP Request/Reply、1秒再送タイマ、target_mac_valid 出力 |
| `tcp_rx_hdr_dec.sv` | Eth+IP+TCP バイト解析、IP/TCP チェックサム検証、ペイロード書き込み |
| `tcp_hdr_gen.sv` | Eth+IP+TCP 60Bヘッダ生成、2パスチェックサム、ゼロパッド |
| `tcp_state_ctrl.sv` | 8状態 TCP FSM (Active Open)、SYN/FIN/RST/ACK 処理、タイムアウト |
| `tcp_layer.sv` | TCP サブモジュール結線トップ |
| `frame_mux.sv` | EtherType ファンアウト (0x0806→ARP, 0x0800→TCP) |
| `toe_engine.sv` | frame_mux + arp_engine + tcp_layer + TX アービタ |
| `axi4lite_regs.sv` | AXI4-Lite スレーブ、レジスタマップ、xpm_fifo_async x2 CDC |
| `toe_top.sv` | IBUFG/BUFG、4段リセット SR、MDC生成、rmii_mac + regs + engine 結線 |

#### 制約ファイル (`vivado/constrs/`)

| ファイル | 内容 |
|---------|------|
| `toe_top.xdc` | PMOD JC ピン配置 (V15/U15/V17/V18/T15/R17/T17/U17)、ref_clk T11 = 50 MHz、false_path CDC 宣言 |

#### ドキュメント (`docs/`)

| ファイル | 内容 |
|---------|------|
| `toe_design.md` | 設計仕様書 (モジュール階層、レジスタマップ、手順、ファームウェア例) |
| `history.md` | 本ファイル — 設計履歴 |

---

### タイムアウト定数まとめ (50 MHz 基準)

| イベント | 時間 | クロック数 |
|---------|------|----------|
| SYN 再送あきらめ | 3 秒 | 150,000,000 |
| TIME_WAIT (2MSL) | 100 ms | 5,000,000 |
| データ再送 | 200 ms | 10,000,000 |
| ARP 再送 | 1 秒 | 50,000,000 |

---

### Phase 1 との差分

| 項目 | Phase 1 | Phase 2 (今回) |
|------|---------|---------------|
| 対応プロトコル | ARP Reply のみ | TCP Full Stack |
| ARP | Reply のみ (受動) | Request + Reply (能動解決) |
| TCP | なし | 8状態 FSM、Active Open |
| TX バッファ | なし | 8KB 循環バッファ (再送対応) |
| RX バッファ | なし | 4KB FIFO |
| AXI4-Lite | なし | レジスタマップ + CDC |
| クロック設計 | clk_50 のみ | clk_50 + s_axi_aclk (非同期 CDC) |

---

### 今後の課題 (未実装)

- MDIO 制御レジスタ (PHY リンク状態確認)
- 複数同時接続対応
- TCP タイムスタンプオプション
- MSS ネゴシエーション
- Selective ACK (SACK)
- IPv6 対応
