# MT4用Lite版EA仕様書（Slim＋AML／統合版・最終・日本語）


---

## 1. スコープ & 目的

* **対象**：MetaTrader4（ヘッジ可、LotStep=0.01推奨）
* **入力**：価格／スプレッド／時刻／建玉（**インジ不要**）
* **運用目標（サイクル黒字）**
  **OR** ① `CycleTP_money` 到達 ② **Basket-BE＋ε**（= サイクル内**累計コスト** × `BasketTP_costMult`）到達 → **全決済**
  **AND** `MaxDD_pct` または `CycleTimeLimit_min` 到達 → **強制全決済** → **Stepを一段拡大**して再敷設（必要時 Re-Anchor）

---

## 2. 用語・単位・基本式

* **pips 定義**：`pip = (Digits==3 || Digits==5) ? 10*Point : Point`
  以降、`Step / SpreadFloor / MaxSlippage_pips` は **pips**基準。価格オフセットは **Point**で計算。
* **Step**：`Step = StepFactor × max(Spread_now, SpreadFloor)`（常時更新・**新規にのみ適用**）
* **SpreadCap**：`時間帯ローリング中央値 × SpreadCapMult`
* **総コスト（1クローズ）**：`Spread×pipValue + 手数料 + 想定滑り(=0.1pips)×pipValue`
* **ε\_profit（Basket-TP閾値）**：`（サイクル内の実際に発生した決済コスト累計）× BasketTP_costMult`
* **ε\_cap（許容赤域）**：`総コスト × Trim_EpsCap_costMult`
* **NetExposure / NetAvg**：
  `NetUnits = |ΣBuy(lot) − ΣSell(lot)|`、
  `NetAvg = (Σ(“NetExposureの向き”のポジの lot×建値)) / Σ(同 lot)`

---

## 3. 管理範囲・口座/ブローカー前提

* **管理対象**：本EAは**チャートのシンボル**かつ**自EAのMagic**のみ管理。**他EA/手動**は完全に無視。
* **ヘッジ可**、**LotStep/最小Lot**に準拠（発注前に丸め）。
* **StopLevel/FreezeLevel**：起動時に取得しログ出力。抵触時は価格再計算（許容内へ） or 次ループへ延期。
* Pip価値は `MarketInfo(Symbol(), MODE_TICKVALUE)` を都度参照。
* 手数料は片道/往復で入力設定（未設定時は ECN 想定：往復 \$7/lot）。

---

## 4. 入力パラメータ（主要）

**基本**：`Lot_U=0.01`、`StepFactor=2.5`、`SpreadFloor=0.6`、`SpreadCapMult=1.5`、`MaxLayers=9`、`MaxUnits=10`、`CycleTP_money=$30`、`BasketTP_costMult=1.15`、`MaxDD_pct=15`、`CycleTimeLimit_min=360`

**ゲート**：`UseSessionWindow=true`、`SessionStart=13:00`、`SessionEnd=23:00`、`MedianWindow_min=60`

**自浄**：`Tau_CB=0.30`、`MicroLIFO_ProfitMult=1.2`、`MicroLIFO_MaxStreak=2`、`Trim_Beta=0.95`、`Trim_EpsCap_costMult=0.20`、`Trim_Cooldown_min=10`、`Ladder_Stall_min=15`、`Ladder_Wait_min=3`

**TREND**：`Trend_HitK=5`、`Trend_Window_min=30`、`Trend_DistMult=8`、`Cooldown_min=45`、`Reanchor_DistMult=9`、`Reanchor_Hold_min=30`

**AML**：`AML_Enable=true`、`AML_Levels=[0.5,1.5]`（順次2段・同時1枚）、`AML_TP_SpreadMult=1.2`、`AML_TTL_min=10`、`AML_Whipsaw_Losses=2`、`AML_Whipsaw_Window_min=30`、`AML_Whipsaw_Cooldown_min=60`、`AML_CB_MinCostMult=3.0`

**実行**：`TimerInterval_ms=500`、`Retry_Max=5`、`Backoff_ms=250`、`MaxSlippage_pips=0.5`、`MagicBase=246800`、`CommentTag="BBG++"`、`Persist_Enable=true`、`OpsPerMinute_SoftCap=12`

**内部クランプ**：`Step ≥ 1.5×Spread_now`／口座安全枠超の `MaxUnits` は自動減額＋警告。

---

## 5. 状態モデル

* **Regime**：`NORMAL` / `TREND`
* **Cycle**：`RUNNING` / `CLOSING` / `RESTART`
* **AML**：`OFF` / `LV1_ACTIVE` / `LV2_ACTIVE` / `COOLDOWN`
* **Gates**：`SpreadGate` / `TimeGate`（緊急・全畳み中は無視）

---

## 6. 注文設計

* **両側グリッド（注文種別明記）**：
  Buy Limit = `P0 − n×Step`、Sell Limit = `P0 + n×Step`（n=1..MaxLayers）。**新Stepは新規にのみ適用**。
  `MaxUnits`は**保有本数**で判定。**保留の敷設総数**は「`MaxUnits − 保有本数`」範囲内のみ。ギャップで保有が増え上限超過した場合は、**次Timerで保留を整理**（保有は維持）。
* **露出**：`Lot_U=0.01` 固定、露出は本数（`MaxUnits`）で制御。
* **勝ちの複製（任意）**：既定OFF。ON時は**含み益≥Step**、SpreadGate通過、`MaxUnits`内で**同方向にLot\_U×1**。
* **AML（逆行順張りスキャル）**：推進方向へ **Stop 0.01**（段1→段2の**順次**、**同時は常に1枚**）。
* **TP/SLポリシー**：ブローカーTPは**AMLのみ**（`AML_TP_SpreadMult × Spread`）。**物理SLなし**。主出口は**仮想 Basket-TP/SL(MaxDD)**。
* **識別子**：`Magic = MagicBase + RoleCode`（例：Grid=10/Micro=20/Trim=30/AML=40）。`Comment = [CycleID]-[Role]-[n]`。

---

## 7. ゲート（Spread/Time）

* **SpreadGate**：`Spread_now ≤ SpreadCap`（**Tickベース**の60分ローリング中央値×`SpreadCapMult`）。
* **TimeGate**：`SessionStart ≤ now < SessionEnd`（ブローカー時刻）。
* **適用範囲**：新規（グリッド/AML）・部分決済（Micro-LIFO/Trim/ラダー）に適用。
  **例外**：**AMLのTTL到達クローズ**はGate無視で実行。緊急（MaxDD/TimeLimit/全畳み）はGate無視。
* **中央値実装**：Tick毎にspreadを配列保存→**60分ローリング**でq50（重ければM1×60本代替）。

---

## 8. 退出ロジック（全畳み）

**トリガ**：① **Basket-TP**（`実現＋含み ≥ ε_profit`）② **CycleTP**（`CycleTP_money`）③ **MaxDD** ④ **CycleTimeLimit**

**手順**：

1. **新規停止**（保留取消）
2. **含み益の大きい順**に OrderClose（LIFO優先可）
3. 残り（負け玉）をクローズ

**再敷設**：全畳み後は **Step×1.3** に一段拡大（最大2段）して再起動。必要時 Re-Anchor を併用。
**再試行**：`Trade context busy/Off quotes/Requote` は指数バックオフで `Retry_Max` 回まで。全畳み中は**SpreadGate無視**。

---

## 9. 自浄モジュール

### 9.1 Cycle Buffer（CB）

* **定義**：サイクル実現益×`Tau_CB`。利確で**加算**、Trim費用で**控除**。サイクル全畳みで**0にリセット**。
* **加算対象**：**Micro-LIFO／AML-TP／ラダーの利確**（Cost後純益）×`Tau_CB`。

### 9.2 Micro-LIFO（勝ち剥がし）

* **条件**：SpreadGate通過中 & **最新の有利玉**の**純益 ≥ `MicroLIFO_ProfitMult × Spread`**。
* **動作**：その **1本だけ**利確 → 利益×`Tau_CB` をCBへ。**同方向連続2回**まで。

### 9.3 Trim Lite（最遠の重しを間引く）

* **候補**：**最遠の負玉1本**（選定：**NetAvgからの距離**→**損失額**→**古さ**）。
* **条件**：`CB ≥ |loss|×Trim_Beta + CloseCost` かつ **Trim後 BasketPnL ≥ −ε\_cap**。
* **頻度**：`Trim_Cooldown_min` に **1回**まで。費用はCBから控除。

### 9.4 BEラダー（2手）

* **開始**：`BasketPnL ∈ [−ε_cap, +ε_profit)` に**連続で**`Ladder_Stall_min`滞留（帯域外に1Tickでも出たらリセット）。
* **手順**：**LIFO勝ち2本**利確 → **`Ladder_Wait_min`** 待機 → **Trim1本**（CB範囲内）。
* **終了**：帯域離脱 or **CB枯渇**。

---

## 10. TREND防御 & Re-Anchor

### 10.1 TREND発火

* **条件（いずれか）**：
  ① **同方向ヒット ≥ `Trend_HitK` / `Trend_Window_min`**（直近30分の\*\*“新規約定”片側本数\*\*）
  ② `|Price − P0| ≥ Trend_DistMult × Step`
* **対処**：**新規停止**／**Step×2.0**／**MaxUnits−40%**（**新規のみ制限**）／**Cooldown\_min** 経過で解除。
  発火時は**保留Limitを全取消**。保有の強制クローズは**行わない**。

### 10.2 Re-Anchor

* **条件**：`|Price−P0| ≥ Reanchor_DistMult × Step` が **`Reanchor_Hold_min`** 継続。
* **動作**：**保留のみ全取消** → `P0’ = 現値` で再敷設。**保有は維持**。
* **Step**：Re-Anchor後も**拡大済みStepを維持**。**全畳み→再起動時のみ**「×1.3段拡大」を適用。

---

## 11. AML（Adverse Momentum Ladder：逆行順張り）

* **目的**：逆行時に**推進方向で小口利確**→**CB補給**を加速。
* **起動**：① TREND中 ② `|Price − NetAvg| ≥ 5×Step`（SpreadGate必須）。
* **方向決定**：`sign(Price−NetAvg)` と **直近10分の高安更新方向**が一致する側を“推進”。
* **配置**：推進方向に **Stop 0.01** を順次最大2段。
  段1：`±0.5×Step`（**同時稼働は常に1枚**）／ 段2：段1の **TP/TTL/取消後**に `±1.5×Step`（かつ **CB ≥ `AML_CB_MinCostMult × 直近1約定コスト中央値`**）
* **決済**：**TP=`AML_TP_SpreadMult × Spread`（ブローカーTP）** or **TTL=`AML_TTL_min`**、**SLなし**。利確の**30%をCB**に加算。
* **ガード**：**`AML_Whipsaw_Losses` 回 / `AML_Whipsaw_Window_min`** で連敗 → **`AML_Whipsaw_Cooldown_min`** 停止。
* **露出制御**：`NetUnits ≥ MaxUnits×0.7` で AML 新規OFF。
* **取消**：TREND解除 / Re-Anchor / SpreadGate違反で**未約定AML保留を全取消**。
* **優先順位（衝突時）**：
  `MaxDD/TimeLimit ＞ Basket-TP/CycleTP ＞ ラダー ＞ Trim ＞ Micro-LIFO ＞ AML ＞ 新規グリッド`

---

## 12. 実行ループ（OnTimer）& 同時制御

* **OnTimer = 500ms**、**1ループ＝最大1アクション**（新規/取消/決済のいずれか1件）。
* **優先順位（処理順）**：

  1. 緊急：`MaxDD` / `CycleTimeLimit` → 全畳み
  2. Basket-TP / CycleTP → 全畳み
  3. ラダー → Trim → Micro-LIFO（ゲート順守）
  4. TREND対応（凍結・Step/MaxUnits調整・AML状態管理）
  5. グリッド敷設/取消（ゲート順守）
* **送信キュー**：`OrderSend/Close/Delete` は**逐次**・指数バックオフ（`Retry_Max`/`Backoff_ms`）。
* **実行負荷のソフト上限**：**1分あたりの操作回数 = min(12, MaxUnits)** をログで制御（テスター暴走防止）。

---

## 13. 丸め・正規化・価格帯処理

* **Lot丸め**：ブローカーの `LotStep` に正規化（未満は切上げ）。
* **価格正規化**：全価格は `NormalizeDouble(price, Digits)`。
* **StopLevel/FreezeLevel抵触**：許容内に**価格再計算**（必要なら**成行±MaxSlippage\_pips**へ切替）。不可なら**次ループ延期**。

---

## 14. セッション・週末

* **TimeGate**中は**新規停止**（グリッド/AML/Micro-LIFO由来の新規）。**クローズ系（LIFO/Trim/全畳み）は許可**。
* **週末**：金曜クローズ前の自動クローズは行わない（TimeLimit/MaxDDのみ）。ロールオーバーのスプレッド悪化は**SpreadGate**で自然停止。

---

## 15. 永続化 & 復旧

* **スナップショット**：`P0, Step, Regime, CycleID, CB, MaxUnits, AML状態` を GV＋ファイル（`MQL4/Files/BBGpp_state.ini|csv`）に保存。
* **優先度**：不整合時は **GV優先**で復元。存在しないチケットは破棄して保留を再敷設。
* **起動復旧**：自Magicの保有があれば**サイクル継続として復元**。保留は仕様どおり再構築（不足レベルのみ）。

---

## 16. BasketPnL/コスト計算（MT4関数準拠）

* **実現PnL**＝サイクル中クローズ注文の`(OrderProfit + OrderSwap + OrderCommission)`累計。
* **含みPnL**＝保有注文の`(OrderProfit + OrderSwap)`合計（Commissionは未確定のため含めない）。
* **判定**：`(実現PnL + 含みPnL) ≥ ε_profit` または `≥ CycleTP_money`。
* **ε\_profit**は「**サイクル内で実際に発生した決済コストの累計**×`BasketTP_costMult`」。

---

## 17. ログ・テレメトリ

* **取引ログ**（1取引1行）：`ts,sym,reason,ticket,role,lot,price,pnl_net,cb_after,spread,step,regime`
* **理由コード**：`BTP, CTP, MDD, TL, M_LIFO, TRIM, LADDER, AML_TP, AML_TTL, AML_STOP, REANCHOR, TREND_ON, TREND_OFF, GATE_BLOCK`
* **サイクルサマリ**：`cycle_id,trades,gross,cost,net,max_dd,cycle_age,reanchors,trend_hits`

---

## 18. 既定値・テスト指針（参考）

* **Step拡大量**：全畳み再起動時に **×1.3**（最大2段）。
* **FreeMarginガード**：`FreeMarginRatio < 120%` で新規OFF、`<110%` で保留取消。
* **TDS推奨**：リアルティック／可変スプレッド／往復\$7/lot／滑り0.1–0.3p／遅延200–400ms。
* **採択KPI**：コスト後の**純益/約定中央値 ≥ 1.2×（Spread+手数料）**、**ピークDD ≤ MaxDD\_pct**、**BE滞留時間短縮**、**busy/拒否件数の低水準**。

---

## 19. 実装ノート（明確化・最終追記）

1. **Magicの一意化（複数チャート）**：`Magic = MagicBase + RoleCode + symbolHash`（*symbolHash*＝シンボル名の簡易ハッシュ。例：`sum(bytes(Symbol())) % 1000`）。
2. **手動クローズの取扱い**：自Magicの手動決済は**実現PnL・決済コスト・CB加算/控除**に即時反映。サイクルは**継続**。
3. **AMLの方向ロック**：AMLは**起動時の推進方向をロック**。TREND解除／Re-Anchor／Whipsaw停止／段TP/TTL／Gate違反まで**途中反転しない**。
4. **「直近1約定コスト中央値」の定義**（AML段2用）：直近**N=20件の実決済**から1注文あたりのコスト（Spread×pipValue＋Commission＋想定滑り0.1p×pipValue）を収集し**中央値**を用いる。履歴がN未満のときは `SpreadFloor×pipValue + 片道手数料 + 想定滑り0.1p×pipValue` を暫定使用。
5. **グリッド敷設の近接制限対処**：StopLevel/FreezeLevelに抵触するPending価格は**許容内ギリへ丸め**、なお不可なら**そのレベルはスキップ**（次のTimerで再評価）。
6. **注文走査の安定化**：注文の選別・クローズは **`for(i=OrdersTotal()-1; i>=0; i--)` の降順ループ**で実施（インデックスずれ防止）。
7. **価格サイドの明示**：PnL/判定は **買い系=Ask／売り系=Bid** を使用。Pendingの価格計算は `P0 ± n×Step×pip` を `NormalizeDouble(...,Digits)` で固定。

---

