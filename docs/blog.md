# FPGAでTCP/IPを自力実装してみた — TOE（TCP Offload Engine）への挑戦

> ZYBO Z7-20 + LAN8720 で Ethernet を動かし、ARPまでは成功。
> TCPのSYNパケットが「物理的には出ているのにWiresharkに映らない」という罠にはまった話。

---

## はじめに：なぜFPGAでTCPを実装するのか

「TCP/IPスタックはOSが提供するもの」というのが常識だ。しかしFPGAにはOSがない。正確には、ZYBOのようなSoC（System on Chip）では ARM コアがあるのでLinuxを動かすことも可能だが、今回のテーマは逆だ。

**ARMではなくFPGA（PL）側にTCP/IPスタックを実装する**、いわゆる **TOE（TCP Offload Engine）** を一から自作してみた。

なぜそんなことをするのか？ 主な理由は：

- **レイテンシの極小化**: CPUを介さずハードウェアで直接パケット処理
- **高スループット**: 100Mbps の帯域をソフトウェアオーバーヘッドなしに使い切る
- **学習目的**: 「TCP/IPを完全に理解した」という状態になりたい

今回は ZYBO Z7-20 に格安の Waveshare LAN8720 ETH ボードを組み合わせ、SystemVerilog で TCP フルスタックの実装に挑んだ。ARPまでは動いた。TCPのSYNは……まだ戦っている。

---

## 使った機材

### ZYBO Z7-20

Xilinx Zynq-7020 を搭載した定番の FPGA ボード。Zynq は ARM Cortex-A9 + FPGA が一体になった SoC で、ARMからFPGAの回路をAXI4-Liteバス経由でレジスタアクセスできる。今回はARMからの指示でFPGAがパケットを生成・送受信するという構成をとった。

### Waveshare LAN8720 ETH ボード

秋月電子などで1,000円前後で買える LAN8720A PHY チップ搭載の小型モジュール。**RMII（Reduced Media Independent Interface）** インターフェースで接続する。RMII は MII の簡略版で、50MHz クロックで 2bit ずつデータを送受信し、100Mbps を実現する。

このモジュールの特徴的な点は **LAN8720A の発振器をFPGAのクロックソースとして使える** こと。INT/RETCLKピンから50MHzが出てくるので、それをFPGAのリファレンスクロックとして使った。

---

## ハードウェア接続（ピンアサイン）

PMOD コネクタに直結した。JC と JB の一部ピンを使っている。

```
FPGA ピン   PMOD     LAN8720 ピン   信号名
─────────────────────────────────────────────
T12        JC4_P    INT/RETCLK     ref_clk (50MHz)  ← クロックソース
V15        JC1_P    TX0            rmii_txd[0]
V7         JB2_N    TX1            rmii_txd[1]
W14        JC3_P    TX-EN          rmii_tx_en
Y14        JC3_N    RX0            rmii_rxd[0]
W15        JC1_N    RX1            rmii_rxd[1]
T11        JC2_P    CRS_DV         rmii_crs_dv
T10        JC2_N    MDC            mdc (1MHz)
U12        JC4_N    MDIO           mdio (Hi-Z)
```

一点ハマったのが **T12 ピンが Clock-Capable IO ではない** こと。Vivado はここに `BUFG` を自動挿入してくれないので、`BUFG` を明示的にインスタンス化する必要があった。さらに `set_property CLOCK_DEDICATED_ROUTE FALSE` を制約ファイルに書かないとルーティングエラーになる。

```systemverilog
// toe_top.sv
BUFG u_clk_buf (.I(ref_clk), .O(clk_50));
```

```tcl
# toe_top.xdc
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets ref_clk_IBUF]
set_clock_latency -source 3.000 [get_clocks ref_clk]  # 非CCIO遅延を補正
```

---

## システム構成

```
┌─────────────────────────────────────────────────────┐
│ FPGA (PL)                                           │
│                                                     │
│  LAN8720 PHY                                        │
│     │ RMII 50MHz 2bit                               │
│  rmii_mac ─────────────────────────────┐            │
│     │ AXI-Stream (byte stream)          │            │
│  frame_mux                             │            │
│  ├─ EtherType 0x0806 → arp_engine ──→ TX Arbiter   │
│  └─ EtherType 0x0800 → tcp_layer  ──→ (ARP優先)    │
│       ├─ tcp_rx_hdr_dec                │            │
│       ├─ tcp_hdr_gen  ──────────────→  │            │
│       ├─ tcp_state_ctrl  (8状態FSM)    │            │
│       ├─ tx_buffer    (8KB 循環BUF)    │            │
│       ├─ rx_buffer    (4KB FIFO)       │            │
│       └─ lfsr_isn     (ISN生成)        │            │
│                                        │            │
│  axi4lite_regs ← xpm_fifo_async (CDC) │            │
│     │ AXI4-Lite                                     │
└─────┼───────────────────────────────────────────────┘
      │
   ARM Cortex-A9 (PS)
   UARTシェルからコマンド操作
```

2つのクロックドメインが存在する。`clk_50`（LAN8720由来）と `s_axi_aclk`（ARM由来）は同じ50MHzだが**非同期**。制御信号は2段FFで同期、データは `xpm_fifo_async` でCDCしている。

---

## ARPエンジン実装 ─ 初めて Wireshark に映った日

TOEを動かすにはまずARPが動く必要がある。TCP SYNを送っても相手のMACアドレスを知らなければEthernetフレームの宛先が書けないからだ。

ARP エンジンの主な機能：
1. **ARP Request 送信**: 相手IPのMACアドレスを問い合わせるブロードキャスト
2. **ARP Reply 受信**: 返ってきた応答からMACアドレスを取得
3. **ARP Reply 送信**: 自分へのARP Requestに応答する

実装は約300行のSystemVerilog。60バイトのARPパケットを `pkt_buf` 配列に組み立て、バイトストリームとして送信する。

```systemverilog
// ARP Request パケット構築（組み合わせ論理）
always_comb begin
    // Ethernetヘッダ
    pkt_buf[0]  = pkt_dst_mac[47:40];  // 宛先MAC (ブロードキャスト FF:FF:FF:FF:FF:FF)
    ...
    pkt_buf[12] = 8'h08; pkt_buf[13] = 8'h06;  // EtherType = ARP
    // ARPヘッダ
    pkt_buf[20] = 8'h00;
    pkt_buf[21] = is_reply_pkt ? 8'h02 : 8'h01;  // OPER: 1=Request, 2=Reply
    ...
end
```

UARTシェルから `arp` コマンドを叩いたとき、初めてWiresharkに以下が現れた瞬間は素直に嬉しかった。

```
No.  Time        Source              Destination  Protocol  Info
281  48.349965   02:00:00:00:00:01   Broadcast    ARP       Who has 192.168.1.20? Tell 192.168.1.100
```

`02:00:00:00:00:01` — 自分で設定したローカル管理MACアドレスが、本物のEthernetフレームとしてネットワークに出た。

### 途中でつまずいたバグ：`ARP_RESOLVED` 後の再トリガ問題

ARPが1回成功するとFSMが `ARP_RESOLVED` 状態に入り、そこで `send_req` を受け付けなかった。2回目以降の `arp` コマンドはHWレベルで無視され、SWのログが「成功」と表示するだけという分かりにくいバグ。

```systemverilog
// 修正前（バグ）: IDLE状態のみでしかトリガを受け付けない
if (send_req && arp_state == ARP_IDLE) begin

// 修正後: RESOLVED後も再トリガ可能に
if (send_req && (arp_state == ARP_IDLE || arp_state == ARP_RESOLVED)) begin
    target_mac_valid <= 1'b0;  // 再解決のためリセット
    arp_state <= ARP_WAIT_REPLY;
    do_request <= 1'b1;
end
```

---

## TCPエンジン実装 ─ 長い戦いの始まり

ARPが動いたので次はTCPだ。RFC 793に基づく8状態FSMを実装した。

```
CLOSED → SYN_SENT → ESTABLISHED → FIN_WAIT_1 → FIN_WAIT_2 → TIME_WAIT
                 ↘ CLOSE_WAIT → LAST_ACK ↗
```

今回実装したのは **Active Open** のみ（FPGAからサーバーへ接続する側）。ARMから `connect_req` レジスタを立てると SYN を送信し、SYN-ACK が返ってきたら ESTABLISHED に遷移する設計だ。

### TCPヘッダ生成の仕組み：2パスチェックサム計算

TCPヘッダ生成 (`tcp_hdr_gen.sv`) の一番の難所はチェックサムだ。TCPチェックサムはペイロード全体を含むため、**ペイロードを全部読まないと確定しない**。しかしAXI-Streamはバックプレッシャができない（データは流れ続ける）。

解決策として2パス方式を採用した：

```
Pass 1 (S_CSUM_PAYLOAD): tx_bufferからペイロードを読み込みながらチェックサムを蓄積
     ↓
S_BUILD: 最終チェックサムを確定 → 54バイトのヘッダバッファ (hdr_buf) を構築
     ↓
Pass 2 (S_SEND_HDR → S_SEND_PAYLOAD): ヘッダを送信後、tx_bufferを再読してペイロードも送信
```

SYNパケット（ペイロードなし）はPass 1をスキップして S_BUILD から直接 S_SEND_HDR に進む。

---

## SYNが「物理的には出ているのにWiresharkに映らない」問題

ここからが本番の戦いだ。

### デバッグLEDによる切り分け

`toe_top.sv` に診断用のstickyLEDを実装した（一度でも条件が成立するとリセットまで点灯し続ける）。

| LED | 条件 | 意味 |
|-----|------|------|
| LD0 | `rmii_tx_en` sticky | PHYが物理的にフレームを送信した |
| LD1 | `arp_mac_valid` sticky | ARP解決成功 |
| LD2 | `tcp_state == SYN_SENT` sticky | TCP状態機械がSYN_SENTに遷移した |
| LD3 | `mac_tx_tvalid` sticky | tcp_hdr_genがMAC TXにデータを出力した |

診断フロー：

```
LD0=OFF           → TX物理パスが壊れている
LD0=ON, LD2=OFF   → connect_req のCDC（クロックドメイン変換）に問題
LD2=ON, LD3=OFF   → tcp_hdr_genが動いていない
LD3=ON, LD0=ON    → SYNはRMIIまで届いている → PC/Wireshark側の問題？
```

`arp` なしで `tcp` だけ実行した結果：

```
> tcp
[TCP] 接続開始 (connect_req=1)...
  100ms  SYN_SENT  (STATUS=0x00000011)   ← SYN_SENT ＆ IRQ発生
 3000ms  SYN_SENT  (STATUS=0x00000001)   ← SYN-ACK なし
 3100ms  CLOSED    (STATUS=0x00000010)   ← 3秒タイムアウト
```

**LEDはLD0/LD2/LD3がすべて点灯**。診断フローによれば「SYNはRMIIまで届いている→PC/Wireshark側の問題」のはずだった。

### 実際の原因は何だったか

Wireshark には何も映らない。ARPは映るのにTCPは映らない。同じネットワーク、同じインターフェース、フィルターは `eth.src == 02:00:00:00:00:01`。

数時間の調査の末に見つけたのが、`tcp_hdr_gen.sv` の `S_SEND_PAD` ステートにある **`tx_tlast` タイミングバグ**だった。

Ethernetフレームは最小64バイト必要で、TCPヘッダ（54バイト）だけでは足りないため6バイトのゼロパディングが追加される。このパディングを送信する `S_SEND_PAD` ステートで、**最終バイト（バイト59）を転送するサイクルに `tx_tlast=1` が間に合っていなかった**。

```systemverilog
// 修正前（バグ）: tx_tlast <= 1'b1 はNBA（非ブロッキング代入）
// バイト59が転送されるサイクルではtx_tlast=0 → append_crcがフレーム末尾を認識できない
S_SEND_PAD: begin
    if (tx_tready) begin
        if (tx_ptr == 7'd59) begin
            tx_tlast <= 1'b1;  // ← 次のクロックで反映されるため間に合わない！
            state    <= S_IDLE;
        end else
            tx_ptr <= tx_ptr + 1'b1;
    end
end
```

AXI-Streamでは `tvalid=1 && tready=1` が同じクロックサイクルに成立した瞬間にデータが転送される。`tx_tlast <= 1'b1` はノンブロッキング代入（NBA）なので**次のクロックで反映**される。バイト59が転送されるサイクルにはまだ `tx_tlast=0` のままだ。

その結果、下流の `append_crc` モジュールはフレームの末尾を認識できず、**FCS（フレームチェックシーケンス/CRC-32）を一切出力しない**。物理的には60バイトのデータが送信されるが、4バイトのFCSがない64バイト未満の不完全フレームになる。PCのNICはハードウェアレベルでFCS不正フレームを廃棄する。だからWiresharkには届かない。

ARPが正常動作するのは `arp_engine` が異なるアプローチをとっているから。

```systemverilog
// arp_engine.sv: 1サイクル先読みで正しくtlastを設定
nxt = tx_ptr + 1'b1;
tx_tdata  <= pkt_buf[nxt];
tx_tlast  <= (nxt == 6'd59);  // バイト58→59の遷移時点でtlast=1を立てる
```

**修正**：バイト58の転送が確定したタイミングで `tx_tlast` を先立てする。

```systemverilog
// 修正後: 1サイクル先読みでtlastをアサート
S_SEND_PAD: begin
    if (tx_tready) begin
        if (tx_ptr == 7'd59) begin
            state    <= S_IDLE;      // tlastはバイト58の時点で立済み
            gen_busy <= 1'b0;
        end else begin
            tx_ptr <= tx_ptr + 1'b1;
            if (tx_ptr == 7'd58) tx_tlast <= 1'b1;  // 先読みアサート
        end
    end
end
```

---

## 現在の状態と今後

現時点での実装状況：

| 機能 | 状態 |
|------|------|
| RMII MAC（送受信） | ✅ 動作確認済み |
| ARP Request/Reply | ✅ Wiresharkで確認済み |
| TCP状態機械（FSM） | ✅ SYN_SENT遷移確認済み |
| TCPヘッダ生成 | 🔧 FCSバグ修正中（再合成待ち） |
| TCP接続確立 | ⬜ 未達成 |
| データ送受信 | ⬜ 未達成 |

`tx_tlast` のタイミングバグを修正して再合成すれば、SYNはWiresharkに映るはずだ。そこからSYN-ACKが返ってきてESTABLISHEDになれば、いよいよデータ転送が試せる。

---

## まとめ：FPGAでTCPを作って分かったこと

- **Ethernetの「当たり前」は全部自分で実装しなければならない** — プリアンブル、SFD、FCS、IPチェックサム、TCPチェックサム（疑似ヘッダ込み）、すべて。
- **クロックドメイン間のデータ受け渡しは難しい** — 2段FF同期、`xpm_fifo_async`、CRCリセット管理など、随所に罠がある。
- **デバッグにはLEDをstickyラッチにするのが有効** — 一瞬しか立たないパルスを見逃さない。
- **AXI-Streamのtlastタイミングは厳しい** — 「次のクロックで反映される」という感覚が直接バグになる。
- **FCSが間違っているとNICがハードウェアで廃棄する** — Wiresharkには一切届かない。この特性が原因特定を難しくした。

全部で約2,000行のSystemVerilogを書いた。TCPの完全動作まであと一歩。続報はまた書く。

---

## 参考

- RFC 793 — TRANSMISSION CONTROL PROTOCOL
- [Waveshare LAN8720 ETH Board](https://www.waveshare.com/wiki/LAN8720_ETH_Board)
- LAN8720A Datasheet — Microchip Technology
- ZYBO Z7 Reference Manual — Digilent
- ebaz4205_ethernet — RMII MAC SystemVerilog実装（参考にさせていただいたコード）
