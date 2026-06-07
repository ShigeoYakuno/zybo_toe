/*
 * iic_sens.c  -  AXI IIC 経由 BME280 / AHT20 センサドライバ
 *
 * sankou/sensors.c を TOE プロジェクト向けに移植。
 * 変更点:
 *   - 関数名: sensors_init → iic_sens_init, sensors_read → iic_sens_read
 *   - IIC_BASE: XPAR_XIIC_0_BASEADDR (= 0x41600000) から取得
 *   - BME280 単体時に湿度も取得できるよう comp_H + 読み出し追加
 *   - 低レベル I2C 関数のトランザクションごとの xil_printf を削除
 *     (エラー時のみ出力に変更)
 */

#include "iic_sens.h"
#include "xiic_l.h"
#include "xil_printf.h"
#include "sleep.h"

/* =====================================================================
 * 定数
 * ===================================================================== */

#define IIC_BASE      IIC_SENS_BASE
#define IIC_TIMEOUT_US  50000U   /* 50 ms: NACK後タイムアウト */

/* =====================================================================
 * モジュール変数
 * ===================================================================== */

static int s_bme280_ok;
static int s_aht20_ok;

/* BME280 キャリブレーションデータ */
typedef struct {
    u16 T1; s16 T2, T3;
    u16 P1; s16 P2, P3, P4, P5, P6, P7, P8, P9;
    u8  H1; s16 H2; u8 H3; s16 H4, H5; s8 H6;
} bme280_cal_t;

static bme280_cal_t s_cal;
static s32          s_t_fine;

/* =====================================================================
 * AXI IIC 低レベルアクセス (Dynamic Mode)
 *
 * XIic_DynSend/Recv は SR_BUS_BUSY を無限ポーリングするためハング危険。
 * DTR / IISR を直接操作し BNB をタイムアウト付きで待つことで回避。
 * ===================================================================== */

/* IISR/SR をポーリングしてトランザクション完了を待つ */
static int wait_idle(int is_read)
{
    /* バスが Busy になるまで最大 500 µs 待つ */
    int bb = 0;
    for (u32 i = 0; i < 500U; i++) {
        if (XIic_ReadReg(IIC_BASE, XIIC_SR_REG_OFFSET) & XIIC_SR_BUS_BUSY_MASK) {
            bb = 1; break;
        }
        usleep(1);
    }
    if (!bb) {
        xil_printf("[IIC] wait_idle: bus never went busy\r\n");
        return -1;
    }

    for (u32 i = 0; i < IIC_TIMEOUT_US; i++) {
        u32 sr   = XIic_ReadReg(IIC_BASE, XIIC_SR_REG_OFFSET);
        u32 iisr = XIic_ReadReg(IIC_BASE, XIIC_IISR_OFFSET);
        if (iisr & XIIC_INTR_ARB_LOST_MASK) return -1;
        if (!(sr & XIIC_SR_BUS_BUSY_MASK))  return 0;
        /* read 完了: TX_ERROR (マスター NACK) が立ったら RX FIFO チェック */
        if (is_read && (iisr & XIIC_INTR_TX_ERROR_MASK)) return 0;
        usleep(1);
    }
    xil_printf("[IIC] timeout SR=0x%02X IISR=0x%02X\r\n",
               (unsigned)XIic_ReadReg(IIC_BASE, XIIC_SR_REG_OFFSET),
               (unsigned)XIic_ReadReg(IIC_BASE, XIIC_IISR_OFFSET));
    return -1;
}

/* TX FIFO リセット + RX FIFO ドレイン + IISR クリア */
static void iic_tx_reset(void)
{
    XIic_WriteReg(IIC_BASE, XIIC_CR_REG_OFFSET, XIIC_CR_TX_FIFO_RESET_MASK);
    XIic_WriteReg(IIC_BASE, XIIC_CR_REG_OFFSET, XIIC_CR_ENABLE_DEVICE_MASK);
    while (!(XIic_ReadReg(IIC_BASE, XIIC_SR_REG_OFFSET) & XIIC_SR_RX_FIFO_EMPTY_MASK))
        (void)XIic_ReadReg(IIC_BASE, XIIC_DRR_REG_OFFSET);
    XIic_WriteReg(IIC_BASE, XIIC_IISR_OFFSET, 0xFFU);
    /* AXI 伝播待ち: 2 回リードバックで確実にクリアを反映 */
    (void)XIic_ReadReg(IIC_BASE, XIIC_IISR_OFFSET);
    (void)XIic_ReadReg(IIC_BASE, XIIC_IISR_OFFSET);
}

/* SOFTR リセット (NACK/エラー後のコア状態リセット) */
static void iic_reset(void)
{
    XIic_DynInit(IIC_BASE);
    usleep(1000);
}

/* START + addr+W + buf[len] + STOP */
static int iic_send(u8 dev, const u8 *buf, u8 len)
{
    iic_reset();
    u32 iisr = XIic_ReadReg(IIC_BASE, XIIC_IISR_OFFSET);
    XIic_WriteReg(IIC_BASE, XIIC_IISR_OFFSET, iisr);   /* W1C: 実値でクリア */
    (void)XIic_ReadReg(IIC_BASE, XIIC_IISR_OFFSET);

    XIic_WriteReg(IIC_BASE, XIIC_DTR_REG_OFFSET,
                  XIIC_TX_DYN_START_MASK | ((u32)dev << 1));
    for (u8 i = 0; i < len; i++) {
        u32 dtr = buf[i];
        if (i == (u8)(len - 1U)) dtr |= XIIC_TX_DYN_STOP_MASK;
        XIic_WriteReg(IIC_BASE, XIIC_DTR_REG_OFFSET, dtr);
    }
    if (wait_idle(0) != 0) return -1;
    return (XIic_ReadReg(IIC_BASE, XIIC_IISR_OFFSET) &
            XIIC_INTR_TX_ERROR_MASK) ? -1 : 0;
}

/* START + addr+R + len バイト受信 + STOP (len <= 16) */
static int iic_recv(u8 dev, u8 *buf, u8 len)
{
    iic_reset();
    u32 iisr = XIic_ReadReg(IIC_BASE, XIIC_IISR_OFFSET);
    XIic_WriteReg(IIC_BASE, XIIC_IISR_OFFSET, iisr);
    (void)XIic_ReadReg(IIC_BASE, XIIC_IISR_OFFSET);

    XIic_WriteReg(IIC_BASE, XIIC_RFD_REG_OFFSET, (u32)(len - 1U));
    XIic_WriteReg(IIC_BASE, XIIC_DTR_REG_OFFSET,
                  XIIC_TX_DYN_START_MASK | ((u32)dev << 1) | 1U);
    XIic_WriteReg(IIC_BASE, XIIC_DTR_REG_OFFSET,
                  XIIC_TX_DYN_STOP_MASK | (u32)len);
    if (wait_idle(1) != 0) return -1;
    if (XIic_ReadReg(IIC_BASE, XIIC_SR_REG_OFFSET) & XIIC_SR_RX_FIFO_EMPTY_MASK)
        return -1;
    for (u8 i = 0; i < len; i++)
        buf[i] = (u8)XIic_ReadReg(IIC_BASE, XIIC_DRR_REG_OFFSET);
    return 0;
}

/* START+addr+W+reg + rSTART+addr+R + len バイト受信 + STOP (len <= 16) */
static int iic_read(u8 dev, u8 reg, u8 *buf, u8 len)
{
    iic_reset();
    u32 iisr = XIic_ReadReg(IIC_BASE, XIIC_IISR_OFFSET);
    XIic_WriteReg(IIC_BASE, XIIC_IISR_OFFSET, iisr);
    (void)XIic_ReadReg(IIC_BASE, XIIC_IISR_OFFSET);

    XIic_WriteReg(IIC_BASE, XIIC_RFD_REG_OFFSET, (u32)(len - 1U));
    XIic_WriteReg(IIC_BASE, XIIC_DTR_REG_OFFSET,
                  XIIC_TX_DYN_START_MASK | ((u32)dev << 1));
    XIic_WriteReg(IIC_BASE, XIIC_DTR_REG_OFFSET, reg);
    XIic_WriteReg(IIC_BASE, XIIC_DTR_REG_OFFSET,
                  XIIC_TX_DYN_START_MASK | ((u32)dev << 1) | 1U);
    XIic_WriteReg(IIC_BASE, XIIC_DTR_REG_OFFSET,
                  XIIC_TX_DYN_STOP_MASK | (u32)len);
    if (wait_idle(1) != 0) return -1;
    if (XIic_ReadReg(IIC_BASE, XIIC_SR_REG_OFFSET) & XIIC_SR_RX_FIFO_EMPTY_MASK)
        return -1;
    for (u8 i = 0; i < len; i++)
        buf[i] = (u8)XIic_ReadReg(IIC_BASE, XIIC_DRR_REG_OFFSET);
    return 0;
}

static int iic_write_reg(u8 dev, u8 reg, u8 val)
{
    u8 buf[2] = {reg, val};
    return iic_send(dev, buf, 2);
}

/* START+addr+STOP のみ送出して ACK/NACK を返す (バススキャン用) */
static int iic_probe(u8 addr)
{
    iic_reset();
    XIic_WriteReg(IIC_BASE, XIIC_DTR_REG_OFFSET,
                  XIIC_TX_DYN_START_MASK | ((u32)addr << 1) | XIIC_TX_DYN_STOP_MASK);
    if (wait_idle(0) != 0) return -1;
    return (XIic_ReadReg(IIC_BASE, XIIC_IISR_OFFSET) &
            XIIC_INTR_TX_ERROR_MASK) ? -1 : 0;
}

/* =====================================================================
 * 公開: I2C バス スキャン
 * ===================================================================== */

void iic_scan(void)
{
    xil_printf("[SCAN] I2Cバス スキャン中 (0x08-0x77)...\r\n");
    int found = 0;
    for (u32 addr = 0x08U; addr <= 0x77U; addr++) {
        if (iic_probe((u8)addr) == 0) {
            xil_printf("[SCAN] ACK addr=0x%02X\r\n", addr);
            found++;
        }
    }
    if (found == 0)
        xil_printf("[SCAN] デバイスなし -- 配線/電源を確認\r\n");
    xil_printf("[SCAN] 完了 %d台\r\n", found);
}

/* =====================================================================
 * 公開: AXI IIC 診断
 * ===================================================================== */

void iic_diag(void)
{
    u32 cr   = XIic_ReadReg(IIC_BASE, XIIC_CR_REG_OFFSET);
    u32 sr   = XIic_ReadReg(IIC_BASE, XIIC_SR_REG_OFFSET);
    u32 iisr = XIic_ReadReg(IIC_BASE, XIIC_IISR_OFFSET);
    xil_printf("[DIAG] reset後: CR=0x%02X(exp 01) SR=0x%02X(exp C0) IISR=0x%02X(exp D0)\r\n",
               (unsigned)cr, (unsigned)sr, (unsigned)iisr);

    XIic_WriteReg(IIC_BASE, XIIC_CR_REG_OFFSET, XIIC_CR_ENABLE_DEVICE_MASK);
    u32 cr_rb = XIic_ReadReg(IIC_BASE, XIIC_CR_REG_OFFSET);
    xil_printf("[DIAG] CR readback=0x%02X %s\r\n",
               (unsigned)cr_rb, (cr_rb == 0x01U) ? "OK" : "NG-AXI失敗");

    iic_tx_reset();
    u32 iisr0 = XIic_ReadReg(IIC_BASE, XIIC_IISR_OFFSET);
    XIic_WriteReg(IIC_BASE, XIIC_DTR_REG_OFFSET,
                  XIIC_TX_DYN_START_MASK | (0x0FU << 1) | XIIC_TX_DYN_STOP_MASK);
    usleep(500);
    u32 sr2   = XIic_ReadReg(IIC_BASE, XIIC_SR_REG_OFFSET);
    u32 iisr2 = XIic_ReadReg(IIC_BASE, XIIC_IISR_OFFSET);
    xil_printf("[DIAG] DTR前IISR=0x%02X  500us後: SR=0x%02X IISR=0x%02X\r\n",
               (unsigned)iisr0, (unsigned)sr2, (unsigned)iisr2);

    if (iisr2 & XIIC_INTR_TX_ERROR_MASK)
        xil_printf("[DIAG] → TX_ERROR/NACK → I2C波形OK (センサー配線/アドレス要確認)\r\n");
    else if ((iisr2 & XIIC_INTR_BNB_MASK) && (iisr0 & XIIC_INTR_BNB_MASK))
        xil_printf("[DIAG] → BNB常時セット: 待機条件の見直しが必要\r\n");
    else if (iisr2 & XIIC_INTR_BNB_MASK)
        xil_printf("[DIAG] → BNBのみ: ACK受信またはタイミング\r\n");
    else
        xil_printf("[DIAG] → 変化なし: STARTが出ていない → クロック/リセット要確認\r\n");

    iic_reset();
}

/* =====================================================================
 * BME280 補正計算 (データシート Appendix B 整数演算版)
 * ===================================================================== */

static s32 comp_T(s32 adc_T)
{
    s32 v1 = ((((adc_T >> 3) - ((s32)s_cal.T1 << 1))) * (s32)s_cal.T2) >> 11;
    s32 v2 = (((((adc_T >> 4) - (s32)s_cal.T1) * ((adc_T >> 4) - (s32)s_cal.T1)) >> 12)
              * (s32)s_cal.T3) >> 14;
    s_t_fine = v1 + v2;
    return (s_t_fine * 5 + 128) >> 8;  /* 0.01°C */
}

static u32 comp_P(s32 adc_P)
{
    s64 v1 = (s64)s_t_fine - 128000;
    s64 v2 = v1 * v1 * (s64)s_cal.P6;
    v2 = v2 + ((v1 * (s64)s_cal.P5) << 17);
    v2 = v2 + ((s64)s_cal.P4 << 35);
    v1 = ((v1 * v1 * (s64)s_cal.P3) >> 8) + ((v1 * (s64)s_cal.P2) << 12);
    v1 = (((s64)1 << 47) + v1) * (s64)s_cal.P1 >> 33;
    if (v1 == 0) return 0U;
    s64 p = 1048576 - adc_P;
    p = (((p << 31) - v2) * 3125) / v1;
    v1 = ((s64)s_cal.P9 * (p >> 13) * (p >> 13)) >> 25;
    v2 = ((s64)s_cal.P8 * p) >> 19;
    p = ((p + v1 + v2) >> 8) + ((s64)s_cal.P7 << 4);
    return (u32)p;  /* Pa × 256 (Q24.8) */
}

/* 湿度補正: t_fine が更新済みであること (comp_T 後に呼ぶ) */
static u32 comp_H(s32 adc_H)
{
    s32 x = s_t_fine - (s32)76800;
    x = (((adc_H << 14) - ((s32)s_cal.H4 << 20) - ((s32)s_cal.H5 * x)) + (s32)16384) >> 15;
    x = x * (((((x * (s32)s_cal.H6) >> 10) *
               (((x * (s32)s_cal.H3) >> 11) + (s32)32768)) >> 10) + (s32)2097152);
    x = ((x * (s32)s_cal.H2) + (s32)8192) >> 14;
    x = x - (((((x >> 15) * (x >> 15)) >> 7) * (s32)s_cal.H1) >> 4);
    x = (x < 0) ? 0 : x;
    x = (x > (s32)419430400) ? (s32)419430400 : x;
    return (u32)(x >> 12);  /* %RH × 1024 */
}

/* =====================================================================
 * BME280 初期化
 * ===================================================================== */

static int bme280_init(void)
{
    u8 buf[16];

    /* ソフトリセット */
    int rc = iic_write_reg(BME280_ADDR, 0xE0, 0xB6);
    xil_printf("[BME] reset=%d\r\n", rc);
    if (rc != 0) return -1;
    usleep(5000);

    /* チップ ID 確認 (0x60=BME280, 0x58=BMP280) */
    rc = iic_read(BME280_ADDR, 0xD0, buf, 1);
    xil_printf("[BME] id_rc=%d id=0x%02X\r\n", rc, rc == 0 ? (u32)buf[0] : 0xFFU);
    if (rc != 0 || (buf[0] != 0x60U && buf[0] != 0x58U)) return -1;

    /* キャリブデータ T1-T3, P1-P5 (0x88-0x97, 16 bytes) */
    if (iic_read(BME280_ADDR, 0x88, buf, 16) != 0) return -1;
    s_cal.T1 = (u16)((buf[1]  << 8) | buf[0]);
    s_cal.T2 = (s16)((buf[3]  << 8) | buf[2]);
    s_cal.T3 = (s16)((buf[5]  << 8) | buf[4]);
    s_cal.P1 = (u16)((buf[7]  << 8) | buf[6]);
    s_cal.P2 = (s16)((buf[9]  << 8) | buf[8]);
    s_cal.P3 = (s16)((buf[11] << 8) | buf[10]);
    s_cal.P4 = (s16)((buf[13] << 8) | buf[12]);
    s_cal.P5 = (s16)((buf[15] << 8) | buf[14]);

    /* キャリブデータ P6-P9 (0x98-0x9F, 8 bytes) — RX FIFO 16byte制限で分割 */
    if (iic_read(BME280_ADDR, 0x98, buf, 8) != 0) return -1;
    s_cal.P6 = (s16)((buf[1] << 8) | buf[0]);
    s_cal.P7 = (s16)((buf[3] << 8) | buf[2]);
    s_cal.P8 = (s16)((buf[5] << 8) | buf[4]);
    s_cal.P9 = (s16)((buf[7] << 8) | buf[6]);

    /* 湿度キャリブ H1 (0xA1) */
    if (iic_read(BME280_ADDR, 0xA1, buf, 1) != 0) return -1;
    s_cal.H1 = buf[0];

    /* 湿度キャリブ H2-H6 (0xE1-0xE7, 7 bytes) */
    if (iic_read(BME280_ADDR, 0xE1, buf, 7) != 0) return -1;
    s_cal.H2 = (s16)((buf[1] << 8) | buf[0]);
    s_cal.H3 = buf[2];
    s_cal.H4 = (s16)(((s16)buf[3] << 4) | (buf[4] & 0x0F));
    s_cal.H5 = (s16)(((s16)buf[5] << 4) | (buf[4] >> 4));
    s_cal.H6 = (s8)buf[6];

    /* 測定設定: osrs_h=1x, osrs_t=1x, osrs_p=1x, mode=normal */
    if (iic_write_reg(BME280_ADDR, 0xF2, 0x01) != 0) return -1;  /* ctrl_hum 先に書く */
    if (iic_write_reg(BME280_ADDR, 0xF4, 0x27) != 0) return -1;  /* ctrl_meas */

    return 0;
}

/* =====================================================================
 * AHT20 初期化
 * ===================================================================== */

static int aht20_init(void)
{
    usleep(40000);  /* 電源投入後 40ms 待機 */

    u8 status;
    int rc = iic_recv(AHT20_ADDR, &status, 1);
    xil_printf("[AHT] status_rc=%d status=0x%02X\r\n", rc, rc == 0 ? (u32)status : 0xFFU);
    if (rc != 0) return -1;

    if (!(status & 0x08U)) {  /* calibration bit 未セット → 初期化コマンド */
        u8 cmd[3] = {0xBE, 0x08, 0x00};
        if (iic_send(AHT20_ADDR, cmd, 3) != 0) return -1;
        usleep(10000);
    }
    return 0;
}

/* =====================================================================
 * 公開 API
 * ===================================================================== */

int iic_sens_init(void)
{
    s_bme280_ok = 0;
    s_aht20_ok  = 0;

    iic_reset();

    if (bme280_init() == 0) {
        s_bme280_ok = 1;
        xil_printf("[SENS] BME280 OK (0x%02X)\r\n", (unsigned)BME280_ADDR);
    } else {
        xil_printf("[SENS] BME280 not found\r\n");
        iic_reset();
    }

    if (aht20_init() == 0) {
        s_aht20_ok = 1;
        xil_printf("[SENS] AHT20 OK (0x%02X)\r\n", (unsigned)AHT20_ADDR);
    } else {
        xil_printf("[SENS] AHT20 not found\r\n");
        iic_reset();
    }

    xil_printf("[SENS] BME280=%s AHT20=%s  base=0x%08X\r\n",
               s_bme280_ok ? "OK" : "NG",
               s_aht20_ok  ? "OK" : "NG",
               (u32)IIC_BASE);
    return 0;  /* センサー未検出でも続行 */
}

void iic_sens_read(int *temp_c10, int *hum_rh10, int *press_hpa10)
{
    *temp_c10    = 0;
    *hum_rh10    = 0;
    *press_hpa10 = 0;

    /* AHT20: 温度 + 湿度 */
    if (s_aht20_ok) {
        u8 trig[3] = {0xAC, 0x33, 0x00};
        iic_send(AHT20_ADDR, trig, 3);
        usleep(80000);  /* 最大 75ms 待機 */

        u8 d[6];
        if (iic_recv(AHT20_ADDR, d, 6) == 0 && !(d[0] & 0x80U)) {
            u32 rh = ((u32)d[1] << 12) | ((u32)d[2] << 4) | (d[3] >> 4);
            u32 rt = ((u32)(d[3] & 0x0FU) << 16) | ((u32)d[4] << 8) | d[5];
            *hum_rh10 = (int)(rh * 1000U / 1048576U);
            *temp_c10 = (int)(rt * 2000U / 1048576U) - 500;
        }
    }

    /* BME280: 気圧 + (AHT20 不在時は温度・湿度も BME280 から取得) */
    if (s_bme280_ok) {
        u8 d[8];
        if (iic_read(BME280_ADDR, 0xF7, d, 8) == 0) {
            s32 adc_P = ((s32)d[0] << 12) | ((s32)d[1] << 4) | (d[2] >> 4);
            s32 adc_T = ((s32)d[3] << 12) | ((s32)d[4] << 4) | (d[5] >> 4);
            s32 adc_H = ((s32)d[6] <<  8) |  (s32)d[7];

            s32 T100 = comp_T(adc_T);   /* t_fine を更新してから P, H を計算 */
            u32 Pq   = comp_P(adc_P);   /* Pa × 256 */

            *press_hpa10 = (int)(Pq / 2560U);  /* Pa×256 / 2560 = 0.1hPa */

            if (!s_aht20_ok) {
                *temp_c10 = T100 / 10;                          /* 0.01°C → 0.1°C */
                *hum_rh10 = (int)(comp_H(adc_H) * 10U / 1024U); /* %RH×1024 → 0.1%RH */
            }
        }
    }
}
