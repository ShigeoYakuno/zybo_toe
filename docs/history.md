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

---

## 2026-06-03 — TCP モジュール バグ修正 (ip_repo)

### 背景

Phase 2 実装後の動作検証で TCP 通信が確立できなかった。
各モジュールの RTL レビューにより以下のバグを発見・修正。

### 修正一覧

#### tcp_rx_hdr_dec.sv  rev1 (2026-06-03)

**バグ:** `rx_tuser` を毎バイト累積して CRC エラー判定していた。  
`mii_mac_rx` は tlast 以外の全バイトで `tuser=1` を出力するため (CRC はフレーム末尾でのみ確定)、
ペイロード書き込み `pl_wr_en` が常時 false になり受信データがバッファに入らなかった。

**修正:** `crc_err` の累積ロジックを削除。`!rx_tuser` の条件を tlast バイトのみで評価するよう変更。

#### tcp_rx_hdr_dec.sv  rev2 (2026-06-03)

**バグ:** `ip_csum_valid`・TCP 疑似ヘッダ `ps_sum` の NBA タイミングバグ。  
`always_ff` 内で `=` (ブロッキング) で計算した値を同サイクル中に `<=` 代入していたため、
Vivado が組み合わせ計算を独立 FF として合成し値が 1 クロック遅れた。

**修正:** `automatic logic` ローカル変数で組み合わせ計算後に NBA 代入するよう変更。

#### tcp_hdr_gen.sv  rev1 (2026-06-01)

**バグ:** `S_IDLE` で `build_hdr()` を即呼び出すと、同サイクルで `<=` 代入した `l_*` レジスタが
まだ未確定のため宛先 MAC が全0になった。

**修正:** `S_IDLE` → `S_BUILD` を経由してから `build_hdr()` を呼ぶ方式に変更。

#### tcp_hdr_gen.sv  rev2 (2026-06-03)

**バグ:** `S_SEND_HDR` で `if (tx_tready)` のみ判定していたため、
`S_BUILD → S_SEND_HDR` 遷移直後の初回サイクル (`tx_tvalid=0`) でも `tx_ptr` がインクリメントされた。
`hdr_buf[1]` がスキップされ FCS が不正 → PC NIC がフレームをハードウェア破棄 → Wireshark に SYN が届かなかった。

**修正:** `if (tx_tready && tx_tvalid)` に変更。

#### tcp_hdr_gen.sv  rev3 (2026-06-03)

**バグ:** `S_SEND_PAD` でバイト59 を転送する瞬間に `tx_tlast=1` が確定している必要があるが、
`tx_ptr==59` で `tx_tlast<=1'b1` (NBA) とすると次クロックで反映されるため、
バイト59が `tlast=0` で転送された。`append_crc` が FCS を出力せずフレームが破棄された。

**修正:** `tx_ptr==58` の転送確定時点で先読みして `tx_tlast<=1'b1` をアサート。

---

## 2026-06-06 — UDP 双方向通信 動作確認・バグ修正

### 背景

Phase 2 の TCP スタックをそのまま使おうとしたが、まず UDP で動作確認することとした。
TCP スタックの udp_layer.sv をベースに UDP 専用のシンプルな実装でデバッグを進めた。

### 確認内容

UART コマンド `send64 <文字列>` で UDP 64バイト送信、PC 側 `udp_server.py` で受信確認。  
PC から UDP パケットを送信し、UART コマンド `recv` で受信文字列を確認。  
→ **双方向 UDP 通信 (FPGA↔PC) 動作確認済み。**

### 修正一覧

#### udp_layer.sv — rx_fifo_wr_en の tuser ゲーティング削除

**バグ:** `rx_fifo_wr_en` に `!rx_tuser` 条件が含まれていた。  
`mii_mac_rx` は tlast 以外の全バイトで `tuser=1` を出力するため (CRC 検証はフレーム末尾でのみ確定)、
ペイロードバイト (42〜104 バイト目) が FIFO に書き込まれなかった。

**修正:** `!rx_tuser` 条件を `rx_fifo_wr_en` から削除。CRC エラーは tlast でのみ検査される。

```systemverilog
// 修正後
assign rx_fifo_wr_en = rx_tvalid && rx_accept
                     && (rx_b_cnt >= 8'd42)
                     && (rx_pay_cnt < 7'(PAYLOAD_BYTES))
                     && !rx_fifo_full;
```

#### axi4lite_regs.sv — xpm_fifo_async RX カウント修正

**バグ1:** `USE_ADV_FEATURES("0004")` は bit2 (wr_data_count) を有効にするが、
bit10 (rd_data_count) を有効にしないため `rx_afifo_rd_count` が常に 0 を出力した。

**バグ2:** `RD_DATA_COUNT_WIDTH` 未指定のためデフォルト 1 bit になり、
64 バイト受信時に `64 mod 2 = 0` → カウント = 0 と読み取られた。

**修正:**
```systemverilog
.USE_ADV_FEATURES    ("0400"),  // bit10 = rd_data_count
.RD_DATA_COUNT_WIDTH (13),      // ceil(log2(4096))+1 = 13
```

#### hdl/constrs/toe_top.xdc — IOB TRUE 制約削除

**バグ:** `set_property IOB TRUE [get_ports {rmii_txd[*] rmii_tx_en}]` が
Vivado 2024.2 で `[Place 30-722]` エラーを発生させた。  
T12 は非 CCIO ピン (`CLOCK_DEDICATED_ROUTE FALSE`) のため、
クロック信号が IOB フリップフロップに届かず配置不可能だった。

**修正:** IOB TRUE 制約行を削除。

---

## 2026-06-06 — TCP モジュール レビュー・rx_buffer バグ修正

### 背景

UDP 動作確認後、TCP モジュール群に同様のバグがないかレビューを実施。

### レビュー結果

| モジュール | 状態 |
|-----------|------|
| tcp_rx_hdr_dec.sv | 修正済み (rev1/rev2 2026-06-03) |
| tcp_hdr_gen.sv | 修正済み (rev1〜rev3 2026-06-03) |
| tcp_state_ctrl.sv | tuser バグなし。tx_busy クリア未実装だが tcp_layer 外部非公開のため ARM に影響なし |
| tx_buffer.sv | xpm_memory_tdpram 使用。FIFO 系バグなし |
| lfsr_isn.sv | 問題なし |
| tcp_layer.sv | 問題なし |

### 修正: rx_buffer.sv — FWFT モードへ変更

**バグ:** `READ_MODE("std")` + `FIFO_READ_LATENCY(1)` を使用していた。  
`axi4lite_regs` のドレイン回路:
```systemverilog
assign rx_rd_en      = !rx_rd_empty && !rx_afifo_full;
assign rx_afifo_din  = rx_rd_data;   // コンビネーショナル接続
assign rx_afifo_wr_en = rx_rd_en;
```
は `empty=0` の時点で `dout` が有効であること (FWFT) を前提とする設計。  
std モードでは `rd_en` アサート後 1 クロックでデータが出るため、
`rx_afifo` に誤データ (旧値) が書き込まれ、ARM が受信した全バイトが化けていた。

**修正:**
```systemverilog
.READ_MODE        ("fwft"),
.FIFO_READ_LATENCY(0),
```

なお `USE_ADV_FEATURES("0000")` のまま `rd_data_count` を接続しているため
`rd_count` は常に 0 を出力するが、`axi4lite_regs` は `rx_afifo_rd_count` (非同期 FIFO 側)
を RX_COUNT レジスタに使用するため ARM の動作に影響しない。
