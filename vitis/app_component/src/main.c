/*
 * TOE インタラクティブテストシェル
 *
 * while(1) で動作し続ける。return 0 はしない。
 * UARTにコマンドを打ち込んでTOEを操作する。
 * コマンド一覧は "help" を参照。
 */

#include "toe_cmd.h"

int main(void)
{
    /* レジスタ設定 + 起動メッセージ表示 */
    toe_cmd_init();

    /* AXI IIC + BME280/AHT20 初期化 */
    iic_sens_init();

    /* メインループ: 終了しない */
    while (1) {
        toe_cmd_poll();
    }

    /* ここには到達しない */
    return 0;
}
