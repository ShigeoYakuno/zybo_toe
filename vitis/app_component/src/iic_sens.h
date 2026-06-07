/*
 * iic_sens.h  -  AXI IIC 経由 BME280 / AHT20 センサドライバ
 *
 * 【Vivado 準備 (AXI IIC 追加済みの場合はスキップ)】
 *   1. Block Design に "AXI IIC" IP を追加
 *   2. Run Connection Automation (AXI Interconnect に接続)
 *   3. IIC ポートを右クリック → "Make External"
 *      ポート名: IIC_0_scl_io / IIC_0_sda_io
 *   4. 制約ファイルに以下を追加 (PMOD JD pin1=T14, pin2=T15):
 *        set_property PACKAGE_PIN T14 [get_ports IIC_0_scl_io]
 *        set_property PACKAGE_PIN T15 [get_ports IIC_0_sda_io]
 *        set_property IOSTANDARD LVCMOS33 [get_ports IIC_0_scl_io]
 *        set_property IOSTANDARD LVCMOS33 [get_ports IIC_0_sda_io]
 *   5. Bitstream 生成 → XSA エクスポート → Vitis プラットフォーム再生成
 *      → xparameters.h に XPAR_XIIC_0_BASEADDR が自動追加される
 *
 * デバイス:
 *   BME280 (0x77): 温度 + 湿度 + 気圧
 *   AHT20  (0x38): 温度 + 湿度  (オプション; 存在すれば優先使用)
 *
 * 出力単位 (× 10 固定小数点):
 *   temp_c10    : 0.1°C  例 211 = 21.1°C, -50 = -5.0°C
 *   hum_rh10    : 0.1%RH 例 591 = 59.1%
 *   press_hpa10 : 0.1hPa 例 10111 = 1011.1hPa
 */

#ifndef IIC_SENS_H
#define IIC_SENS_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * AXI IIC ベースアドレス
 * プラットフォーム再生成後は XPAR_XIIC_0_BASEADDR に自動設定される。
 */
#ifdef XPAR_XIIC_0_BASEADDR
#define IIC_SENS_BASE  XPAR_XIIC_0_BASEADDR
#else
#define IIC_SENS_BASE  0x41600000UL
#endif

/* BME280 I2C アドレス (SDO=VCC → 0x77, SDO=GND → 0x76) */
#define BME280_ADDR  0x77U
/* AHT20 I2C アドレス (固定 0x38) */
#define AHT20_ADDR   0x38U

/*
 * 初期化: AXI IIC リセット → BME280/AHT20 検出 → キャリブレーション読み込み
 * センサー未検出でも 0 を返し続行する (センサーなしでUDP送信テスト可能)
 */
int  iic_sens_init(void);

/*
 * センサデータ読み取り
 * iic_sens_init() を呼んでから使用すること
 */
void iic_sens_read(int *temp_c10, int *hum_rh10, int *press_hpa10);

/* I2C バス全アドレス (0x08-0x77) をスキャンして ACK デバイスを列挙 */
void iic_scan(void);

/* AXI IIC ハードウェア診断 (初期動作確認用) */
void iic_diag(void);

#ifdef __cplusplus
}
#endif

#endif /* IIC_SENS_H */
