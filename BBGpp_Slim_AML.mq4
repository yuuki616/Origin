#property strict
#property copyright "Origin Project"
#property link      ""
#property version   "1.0"
#property description "Slim+AML EA skeleton"

//+------------------------------------------------------------------+
//| 入力パラメータ                                                    |
//+------------------------------------------------------------------+
input double   Lot_U              = 0.01;    // 最小ロット
input double   StepFactor         = 2.5;     // ステップ倍率
input double   SpreadFloor        = 0.6;     // スプレッド下限(pips)
input double   SpreadCapMult      = 1.5;     // スプレッド上限倍率
input int      MaxLayers          = 9;       // 最大レイヤー
input int      MaxUnits           = 10;      // 最大保有本数
input double   CycleTP_money      = 30;      // サイクルTP金額
input double   BasketTP_costMult  = 1.15;    // バスケットTPコスト倍率
input double   MaxDD_pct          = 15;      // 最大ドローダウン%
input int      CycleTimeLimit_min = 360;     // サイクル最大時間

input bool     UseSessionWindow   = true;    // セッション制限
input string   SessionStart       = "13:00"; // セッション開始
input string   SessionEnd         = "23:00"; // セッション終了
input int      MedianWindow_min   = 60;      // スプレッド中央値計測窓

input double   Tau_CB             = 0.30;    // サイクルバッファ係数
input double   MicroLIFO_ProfitMult = 1.2;   // Micro-LIFO 利益倍率
input int      MicroLIFO_MaxStreak  = 2;     // Micro-LIFO 最大連続回数
input double   Trim_Beta          = 0.95;    // Trim ベータ
input double   Trim_EpsCap_costMult = 0.20;  // Trim 許容コスト倍率
input int      Trim_Cooldown_min  = 10;      // Trim クールダウン
input int      Ladder_Stall_min   = 15;      // ラダーストール
input int      Ladder_Wait_min    = 3;       // ラダー待機

input int      Trend_HitK         = 5;
input int      Trend_Window_min   = 30;
input double   Trend_DistMult     = 8;
input int      Cooldown_min       = 45;
input double   Reanchor_DistMult  = 9;
input int      Reanchor_Hold_min  = 30;

input bool     AML_Enable         = true;
input double   AML_Levels[2]      = {0.5,1.5};
input double   AML_TP_SpreadMult  = 1.2;
input int      AML_TTL_min        = 10;
input int      AML_Whipsaw_Losses = 2;
input int      AML_Whipsaw_Window_min = 30;
input int      AML_Whipsaw_Cooldown_min = 60;
input double   AML_CB_MinCostMult = 3.0;

input int      TimerInterval_ms   = 500;
input int      Retry_Max          = 5;
input int      Backoff_ms         = 250;
input double   MaxSlippage_pips   = 0.5;
input int      MagicBase          = 246800;
input string   CommentTag         = "BBG+";
input bool     Persist_Enable     = true;
input int      OpsPerMinute_SoftCap = 12;

//+------------------------------------------------------------------+
//| 定数・列挙体                                                     |
//+------------------------------------------------------------------+
enum Regime { REGIME_NORMAL=0, REGIME_TREND };
enum Cycle   { CYCLE_RUNNING=0, CYCLE_CLOSING, CYCLE_RESTART };
enum AMLState{ AML_OFF=0, AML_LV1_ACTIVE, AML_LV2_ACTIVE, AML_COOLDOWN };

//+------------------------------------------------------------------+
//| グローバル変数                                                   |
//+------------------------------------------------------------------+
double Step;
double SpreadMedian;
double CycleBuffer=0;
double AnchorPrice;
datetime reanchorStart=0;
int    CycleID=0;
int    symbolHash=0;
int    MagicGrid=0;
int    MagicMicro=0;
int    MagicTrim=0;
int    MagicAML=0;
Regime regime=REGIME_NORMAL;
Cycle  cycle=CYCLE_RUNNING;
AMLState aml_state=AML_OFF;
int    lastTimerTick=0;
double StopLevel=0;
double FreezeLevel=0;
double LotStep=0;
double MinLot=0;
double lastSpreadPips=0;      // 直近スプレッド(pips)
// スプレッド履歴(pips)
double   Spreads[];
datetime SpreadTimes[];
// 操作回数制限
datetime opsWindowStart=0;
int      opsCount=0;
// サイクル管理
double stepMult=1.0;
int    stepExpandCount=0;
double cycleStartEquity=0;
datetime cycleStartTime=0;
double cycleCost=0; // サイクル内の決済コスト累計
datetime lastHistoryTime=0;
int    microLifoDir=0;        // Micro-LIFO 連続方向
int    microLifoStreak=0;     // Micro-LIFO 連続回数
int    amlTicket=-1;          // AML 保有チケット
datetime amlOpenTime=0;       // AML オープン時刻
int    amlDir=0;              // AML 方向 1=Buy,-1=Sell
datetime amlCooldownEnd=0;    // AML クールダウン終了時刻
int    amlWhipsawCnt=0;       // AML 連敗数
datetime amlWhipsawWindow=0;  // AML 連敗計測開始

// プロトタイプ
void CloseOneOrder();
bool CloseWithRetry(int ticket,bool addCb);
bool CheckExitConditions();
void RestartCycle();
string BuildComment(string role,int idx);
void RegisterClosure(int ticket,double spreadClose=-1,bool addCb=false);
void UpdateManualClosures();
bool FreeMarginGate();
bool FindPendingLevel(int level,int type);
bool TryMicroLIFO(double spread_pips);
bool HandleAML(double spread_pips,int held);
void CancelAMLPending();
double GetNetAverage(double &netUnits);

//+------------------------------------------------------------------+
//| 初期化                                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   symbolHash = SymbolHash(Symbol());
   MagicGrid  = MagicBase + 10 + symbolHash;
   MagicMicro = MagicBase + 20 + symbolHash;
   MagicTrim  = MagicBase + 30 + symbolHash;
   MagicAML   = MagicBase + 40 + symbolHash;
   AnchorPrice = NormalizeDouble( (Ask+Bid)/2, Digits );
   lastSpreadPips = MarketInfo(Symbol(),MODE_SPREAD) * Point / Pip();
   ArrayResize(Spreads,1);
   ArrayResize(SpreadTimes,1);
   Spreads[0] = lastSpreadPips;
   SpreadTimes[0] = TimeCurrent();
   SpreadMedian = lastSpreadPips;
   Step = CalcStep(lastSpreadPips);
   StopLevel  = MarketInfo(Symbol(),MODE_STOPLEVEL)  * Point;
   FreezeLevel= MarketInfo(Symbol(),MODE_FREEZELEVEL)* Point;
   LotStep    = MarketInfo(Symbol(),MODE_LOTSTEP);
   MinLot     = MarketInfo(Symbol(),MODE_MINLOT);
   Print("Init: Step=",Step," Pip=",Pip()," StopLevel=",StopLevel/Point,
         " FreezeLevel=",FreezeLevel/Point);
   EventSetMillisecondTimer(TimerInterval_ms);
   cycleStartEquity = AccountEquity();
   cycleStartTime   = TimeCurrent();
   cycleCost        = 0;
   CycleBuffer      = 0;
   lastHistoryTime  = cycleStartTime;
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

//+------------------------------------------------------------------+
//| ティック受信                                                     |
//+------------------------------------------------------------------+
void OnTick()
  {
   lastSpreadPips = (Ask-Bid) / Pip();
   UpdateSpreadMedian(lastSpreadPips);
  }

//+------------------------------------------------------------------+
//| タイマー実行                                                     |
//+------------------------------------------------------------------+
void OnTimer()
  {
   double spread_pips = lastSpreadPips;
   Step = stepMult * CalcStep(spread_pips);

   UpdateManualClosures();

   int held=0,pending=0;
   CountOrders(held,pending);

   if(cycle==CYCLE_CLOSING)
     {
      if(pending>0)
        {
         CancelPendingOrders();
         return;
        }
      if(held>0)
        {
         CloseOneOrder();
         return;
        }
      RestartCycle();
      return;
     }

  if(CheckExitConditions())
    {
     cycle = CYCLE_CLOSING;
     return;
    }

   // 保有が上限に達した場合は保留を整理（1ループ1アクション）
  if(held>=MaxUnits)
    {
     if(pending>0) CancelPendingOrders();
     return;
    }

  if(TryMicroLIFO(spread_pips))
     return;

  if(HandleAML(spread_pips,held))
     return;

  if(!FreeMarginGate())
     return;

  int allowedPending = MaxUnits - held;
  if(pending>allowedPending)
    {
      // 過剰な保留注文を1件ずつ整理
      CancelPendingOrders();
      return;
    }

  // Re-Anchor チェック
  double mid = (Ask+Bid)/2.0;
  double distPips = MathAbs(mid - AnchorPrice) / Pip();
  if(distPips >= Reanchor_DistMult * Step)
    {
     if(reanchorStart==0)
       reanchorStart = TimeCurrent();
     else if(TimeCurrent() - reanchorStart >= Reanchor_Hold_min*60)
       {
        if(pending>0)
          {
           CancelPendingOrders();
           return;
          }
        AnchorPrice = NormalizeDouble(mid,Digits);
        reanchorStart = 0;
        Print("ReAnchor");
        return;
       }
    }
  else
    {
     reanchorStart = 0;
    }

  if(!SpreadGate(spread_pips))
    {
     CancelAMLPending();
     return;
    }
  if(!TimeGate())
    {
     CancelAMLPending();
     return;
    }

   PlaceGridOrders(held,pending);
  }

//+------------------------------------------------------------------+
//| グリッド敷設                                                      |
//+------------------------------------------------------------------+
void PlaceGridOrders(int held,int pending)
  {
   int allowedPending = MaxUnits - held;
   if(pending>=allowedPending) return;

   double stepPoints = Step*Pip();
   for(int level=1; level<=MaxLayers && pending<allowedPending; level++)
     {
      double buyPrice = NormalizeDouble(AnchorPrice - level*stepPoints, Digits);
      double sellPrice= NormalizeDouble(AnchorPrice + level*stepPoints, Digits);
      bool needBuy = (buyPrice < Ask && !FindPendingLevel(level,OP_BUYLIMIT));
      bool needSell= (sellPrice> Bid && !FindPendingLevel(level,OP_SELLLIMIT));

      if(needBuy && pending<allowedPending)
        {
         if(SendPending(OP_BUYLIMIT,buyPrice,level))
            pending++;
         return;
        }
      if(needSell && pending<allowedPending)
        {
         if(SendPending(OP_SELLLIMIT,sellPrice,level))
            pending++;
         return;
        }
     }
  }

//+------------------------------------------------------------------+
//| 保有/保留本数カウント                                             |
//+------------------------------------------------------------------+
void CountOrders(int &held,int &pending)
  {
   held=0;
   pending=0;
  for(int i=OrdersTotal()-1;i>=0;i--)
    {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol()) continue;
      int magic=OrderMagicNumber();
      if(magic!=MagicGrid && magic!=MagicAML) continue;
      int type=OrderType();
      if(type==OP_BUY || type==OP_SELL) held++;
      if(type==OP_BUYLIMIT || type==OP_SELLLIMIT || type==OP_BUYSTOP || type==OP_SELLSTOP) pending++;
    }
  }

//+------------------------------------------------------------------+
//| 保留注文の整理（最大count件）                                     |
//+------------------------------------------------------------------+
void CancelPendingOrders(int count=1)
  {
   for(int i=OrdersTotal()-1; i>=0 && count>0; i--)
     {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol()) continue;
      int magic=OrderMagicNumber();
      if(magic!=MagicGrid && magic!=MagicAML) continue;
      int type=OrderType();
      if(type==OP_BUYLIMIT || type==OP_SELLLIMIT || type==OP_BUYSTOP || type==OP_SELLSTOP)
        {
         int ticket=OrderTicket();
         DeleteWithRetry(ticket);
         if(ticket==amlTicket) { amlTicket=-1; aml_state=AML_OFF; }
         count--;
        }
    }
  }

//+------------------------------------------------------------------+
//| AML保留注文の全取消                                             |
//+------------------------------------------------------------------+
void CancelAMLPending()
  {
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MagicAML) continue;
      int type=OrderType();
      if(type==OP_BUYSTOP || type==OP_SELLSTOP)
        {
         int ticket=OrderTicket();
         DeleteWithRetry(ticket);
         if(ticket==amlTicket) { amlTicket=-1; aml_state=AML_OFF; }
        }
     }
  }

//+------------------------------------------------------------------+
//| ネット平均価格とユニット数                                       |
//+------------------------------------------------------------------+
double GetNetAverage(double &netUnits)
  {
   double buyLot=0,sellLot=0,buyVal=0,sellVal=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol()) continue;
      int magic=OrderMagicNumber();
      if(magic!=MagicGrid && magic!=MagicAML) continue;
      int type=OrderType();
      if(type==OP_BUY)  { double lot=OrderLots(); buyLot+=lot;  buyVal+=lot*OrderOpenPrice(); }
      if(type==OP_SELL) { double lot=OrderLots(); sellLot+=lot; sellVal+=lot*OrderOpenPrice(); }
     }
   double diff = buyLot - sellLot;
   netUnits = MathAbs(diff)/Lot_U;
   if(diff>0 && buyLot>0) return(buyVal/buyLot);
   if(diff<0 && sellLot>0) return(sellVal/sellLot);
   netUnits=0;
   return(0);
  }

//+------------------------------------------------------------------+
//| 1件クローズ（含み益順）                                          |
//+------------------------------------------------------------------+
void CloseOneOrder()
  {
   double best= -1e10;
   int bestTicket = -1;
  for(int i=OrdersTotal()-1;i>=0;i--)
    {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol()) continue;
      int magic=OrderMagicNumber();
      if(magic!=MagicGrid && magic!=MagicAML) continue;
      int type=OrderType();
      if(type==OP_BUY || type==OP_SELL)
        {
         double p = OrderProfit()+OrderSwap();
         if(p>best){ best=p; bestTicket=OrderTicket(); }
        }
    }
  if(bestTicket!=-1) CloseWithRetry(bestTicket,false);
  }

//+------------------------------------------------------------------+
//| OrderClose リトライ                                               |
//+------------------------------------------------------------------+
bool CloseWithRetry(int ticket,bool addCb)
  {
   if(!OpsAllowed()) return(false);
   for(int attempt=0; attempt<Retry_Max; attempt++)
     {
      if(OrderSelect(ticket,SELECT_BY_TICKET))
        {
         double lot = OrderLots();
         double price = (OrderType()==OP_BUY)?Bid:Ask;
         int slippage = (int)MathRound(MaxSlippage_pips * Pip() / Point);
         if(OrderClose(ticket,lot,price,slippage,clrRed))
           {
            double spreadClose = (Ask-Bid)/Pip();
            RegisterClosure(ticket,spreadClose,addCb);
            return(true);
           }
        }
      Print("OrderClose failed: ",GetLastError());
      Sleep(Backoff_ms * (1<<attempt));
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| 決済処理の登録（コスト/CB）                                       |
//+------------------------------------------------------------------+
void RegisterClosure(int ticket,double spreadClose,bool addCb)
  {
   if(!OrderSelect(ticket,SELECT_BY_TICKET,MODE_HISTORY)) return;
   double sc = spreadClose;
   if(sc<0) sc = lastSpreadPips;
  double pv   = MarketInfo(Symbol(),MODE_TICKVALUE) * Pip() / Point;
  double comm = MathAbs(OrderCommission());
  cycleCost  += (sc + 0.1) * pv + comm;
  double net = OrderProfit() + OrderSwap() + OrderCommission();
  if(addCb && net>0)
     CycleBuffer += Tau_CB * net;
  datetime ct = OrderCloseTime();
  if(ct>lastHistoryTime) lastHistoryTime = ct;
  int magic = OrderMagicNumber();
  if(magic==MagicAML)
    {
     amlTicket=-1;
     datetime now = TimeCurrent();
     if(net<0)
       {
        if(now - amlWhipsawWindow > AML_Whipsaw_Window_min*60)
          { amlWhipsawCnt=0; amlWhipsawWindow=now; }
        amlWhipsawCnt++;
        if(amlWhipsawCnt >= AML_Whipsaw_Losses)
          {
           amlCooldownEnd = now + AML_Whipsaw_Cooldown_min*60;
           amlWhipsawCnt=0;
           aml_state=AML_COOLDOWN;
          }
        else
          aml_state=AML_OFF;
       }
     else
       {
        amlWhipsawCnt=0;
        amlWhipsawWindow=now;
        aml_state=AML_OFF;
       }
    }
  }

//+------------------------------------------------------------------+
//| 手動クローズの検出                                               |
//+------------------------------------------------------------------+
void UpdateManualClosures()
  {
  for(int i=OrdersHistoryTotal()-1;i>=0;i--)
    {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_HISTORY)) continue;
      if(OrderSymbol()!=Symbol()) continue;
      int magic=OrderMagicNumber();
      if(magic!=MagicGrid && magic!=MagicAML) continue;
      datetime ct = OrderCloseTime();
      if(ct<=lastHistoryTime || ct<cycleStartTime) break;
      RegisterClosure(OrderTicket(),-1,false);
    }
  }

//+------------------------------------------------------------------+
//| 指定レベルの保留注文有無                                         |
//+------------------------------------------------------------------+
bool FindPendingLevel(int level,int type)
  {
   string needle = StringFormat("G-%d",level);
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MagicGrid) continue;
      if(OrderType()==type && StringFind(OrderComment(),needle)>=0)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Micro-LIFO                                                       |
//+------------------------------------------------------------------+
bool TryMicroLIFO(double spread_pips)
  {
   if(!SpreadGate(spread_pips) || !TimeGate())
     {
      microLifoDir=0;
      microLifoStreak=0;
      return(false);
     }

   int    ticket   = -1;
   int    dir      = 0;
   datetime latest = 0;
   double pv = MarketInfo(Symbol(),MODE_TICKVALUE) * Pip() / Point;
   double thresh = MicroLIFO_ProfitMult * spread_pips * pv;

   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MagicGrid) continue;
      int type = OrderType();
      if(type!=OP_BUY && type!=OP_SELL) continue;
      double net = OrderProfit()+OrderSwap()+OrderCommission();
      if(net>=thresh)
        {
         datetime ot = OrderOpenTime();
         if(ot>latest)
           {
            latest = ot;
            ticket = OrderTicket();
            dir    = (type==OP_BUY)?1:-1;
           }
        }
     }

   if(ticket<0)
     {
      microLifoDir=0;
      microLifoStreak=0;
      return(false);
     }
   if(dir==microLifoDir && microLifoStreak>=MicroLIFO_MaxStreak)
      return(false);
   if(dir==microLifoDir) microLifoStreak++;
   else { microLifoDir=dir; microLifoStreak=1; }
   return CloseWithRetry(ticket,true);
  }

//+------------------------------------------------------------------+
//| AML処理                                                          |
//+------------------------------------------------------------------+
bool HandleAML(double spread_pips,int held)
  {
   if(!AML_Enable) return(false);
   datetime now = TimeCurrent();
   if(now < amlCooldownEnd) return(false);

   if(amlTicket>0)
     {
      if(OrderSelect(amlTicket,SELECT_BY_TICKET))
        {
         int type = OrderType();
         if(type==OP_BUY || type==OP_SELL)
           {
            if(amlOpenTime==0) amlOpenTime = OrderOpenTime();
            if(now - amlOpenTime >= AML_TTL_min*60)
              {
               if(CloseWithRetry(amlTicket,true))
                 {
                  amlTicket=-1; aml_state=AML_OFF;
                  return(true);
                 }
              }
           }
         else if(type==OP_BUYSTOP || type==OP_SELLSTOP)
           {
            if(!SpreadGate(spread_pips) || !TimeGate())
              {
               if(DeleteWithRetry(amlTicket))
                 {
                  amlTicket=-1; aml_state=AML_OFF;
                  return(true);
                 }
              }
           }
         return(false);
        }
      else
        {
         amlTicket=-1; aml_state=AML_OFF;
         return(false);
        }
     }

   if(!SpreadGate(spread_pips) || !TimeGate()) return(false);
   if(held >= MaxUnits*0.7) return(false);

   double netUnits=0;
   double netAvg = GetNetAverage(netUnits);
   if(netUnits<=0) return(false);
   double mid = (Ask+Bid)/2.0;
   double dist = MathAbs(mid - netAvg) / Pip();
   if(dist < 5*Step) return(false);

   int hiIdx = iHighest(Symbol(),PERIOD_M1,MODE_HIGH,10,0);
   int loIdx = iLowest(Symbol(),PERIOD_M1,MODE_LOW,10,0);
   double high = iHigh(Symbol(),PERIOD_M1,hiIdx);
   double low  = iLow(Symbol(),PERIOD_M1,loIdx);
   int dir = (mid>netAvg)?1:-1;
   if(dir>0 && mid<high) return(false);
   if(dir<0 && mid>low)  return(false);

   if(!OpsAllowed()) return(false);
   double level = AML_Levels[0];
   int type = (dir>0)?OP_BUYSTOP:OP_SELLSTOP;
   double price = (dir>0)?NormalizeDouble(Ask + level*Step*Pip(),Digits)
                        : NormalizeDouble(Bid - level*Step*Pip(),Digits);
   double tp = (dir>0)?price + AML_TP_SpreadMult*spread_pips*Pip()
                      : price - AML_TP_SpreadMult*spread_pips*Pip();
   double lot = NormalizeLot(0.01);
   string comment = BuildComment("AML",1);
   int slippage = (int)MathRound(MaxSlippage_pips * Pip() / Point);
   for(int attempt=0; attempt<Retry_Max; attempt++)
     {
      int ticket = OrderSend(Symbol(),type,lot,price,slippage,0,tp,comment,MagicAML,0,clrOrange);
      if(ticket>=0)
        {
         amlTicket=ticket; amlDir=dir; aml_state=AML_LV1_ACTIVE; amlOpenTime=0;
         return(true);
        }
      Print("OrderSend AML failed: ",GetLastError());
      Sleep(Backoff_ms * (1<<attempt));
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Pending注文送信                                                  |
//+------------------------------------------------------------------+
bool SendPending(int type,double price,int level)
  {
   if(!OpsAllowed()) return(false);
   double lot = NormalizeLot(Lot_U);
   price = NormalizeDouble(price,Digits);

   double cur   = (type==OP_BUYLIMIT)?Ask:Bid;
   double diff  = MathAbs(cur-price);
   if(diff<StopLevel)
     {
      if(type==OP_BUYLIMIT) price = NormalizeDouble(cur - StopLevel,Digits);
      else                  price = NormalizeDouble(cur + StopLevel,Digits);
      diff = MathAbs(cur-price);
      if(diff<FreezeLevel)
        {
         Print("SendPending postponed: within FreezeLevel");
         return(false);
        }
     }

   string comment = BuildComment("G",level);
   int slippage = (int)MathRound(MaxSlippage_pips * Pip() / Point);
   for(int attempt=0; attempt<Retry_Max; attempt++)
     {
      int ticket = OrderSend(Symbol(),type,lot,price,slippage,0,0,comment,MagicGrid,0,clrAqua);
      if(ticket>=0) return(true);
      Print("OrderSend failed: ",GetLastError());
      Sleep(Backoff_ms * (1<<attempt));
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| OrderDelete リトライ                                              |
//+------------------------------------------------------------------+
bool DeleteWithRetry(int ticket)
  {
   if(!OpsAllowed()) return(false);
   for(int attempt=0; attempt<Retry_Max; attempt++)
     {
      if(OrderDelete(ticket)) return(true);
      Print("OrderDelete failed: ",GetLastError());
      Sleep(Backoff_ms * (1<<attempt));
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| 操作回数制御                                                     |
//+------------------------------------------------------------------+
bool OpsAllowed()
  {
   datetime now = TimeCurrent();
   if(now - opsWindowStart >= 60)
     {
      opsWindowStart = now;
      opsCount = 0;
     }
   int cap = MathMin(OpsPerMinute_SoftCap, MaxUnits);
   if(opsCount >= cap)
     {
      Print("OpsPerMinute soft cap reached: ",cap);
      return(false);
     }
   opsCount++;
   return(true);
  }

//+------------------------------------------------------------------+
//| サイクルトリガ判定                                               |
//+------------------------------------------------------------------+
bool CheckExitConditions()
  {
   double equity = AccountEquity();
   double profit = equity - cycleStartEquity;
   double ddPct = 100.0 * (cycleStartEquity - equity) / cycleStartEquity;
   if(cycleCost>0 && profit >= cycleCost*BasketTP_costMult) return(true);
   if(profit >= CycleTP_money) return(true);
   if(ddPct  >= MaxDD_pct)     return true;
   if(TimeCurrent() - cycleStartTime >= CycleTimeLimit_min*60) return(true);
   return(false);
  }

//+------------------------------------------------------------------+
//| サイクル再起動                                                   |
//+------------------------------------------------------------------+
void RestartCycle()
  {
   AnchorPrice = NormalizeDouble((Ask+Bid)/2,Digits);
  cycleStartEquity = AccountEquity();
  cycleStartTime   = TimeCurrent();
  cycleCost        = 0;
  CycleBuffer      = 0;
  lastHistoryTime  = cycleStartTime;
  CycleID++;
  if(stepExpandCount < 2)
    {
     stepMult *= 1.3;
     stepExpandCount++;
     }
   Step = stepMult * CalcStep(lastSpreadPips);
   cycle = CYCLE_RUNNING;
  }

//+------------------------------------------------------------------+
//| FreeMarginGate                                                   |
//+------------------------------------------------------------------+
bool FreeMarginGate()
  {
   double equity = AccountEquity();
   if(equity<=0) return(true);
   double ratio = 100.0 * AccountFreeMargin() / equity;
   if(ratio < 110.0)
     {
      CancelPendingOrders();
      return(false);
     }
   if(ratio < 120.0)
     return(false);
   return(true);
  }

//+------------------------------------------------------------------+
//| SpreadGate                                                       |
//+------------------------------------------------------------------+
bool SpreadGate(double spread_pips)
  {
   double cap = SpreadMedian*SpreadCapMult;
   if(spread_pips>cap) return(false);
   return(true);
  }

//+------------------------------------------------------------------+
//| TimeGate                                                         |
//+------------------------------------------------------------------+
bool TimeGate()
  {
   if(!UseSessionWindow) return(true);
   datetime now = TimeCurrent();
   string d = TimeToString(now,TIME_DATE);
   datetime start = StringToTime(d+" "+SessionStart);
   datetime end   = StringToTime(d+" "+SessionEnd);
   if(start<=end)
     {
      if(start<=now && now<end) return(true);
      return(false);
     }
   // 日付を跨ぐセッション
   if(now>=start || now<end) return(true);
   return(false);
  }

//+------------------------------------------------------------------+
//| スプレッド中央値更新                                             |
//+------------------------------------------------------------------+
void UpdateSpreadMedian(double spread)
  {
   datetime now = TimeCurrent();
   int n = ArraySize(Spreads);
   ArrayResize(Spreads, n+1);
   ArrayResize(SpreadTimes, n+1);
   Spreads[n] = spread;
   SpreadTimes[n] = now;

   datetime cutoff = now - MedianWindow_min*60;
   int start=0;
   while(start < ArraySize(SpreadTimes) && SpreadTimes[start] < cutoff) start++;
   if(start>0)
     {
      int newSize = ArraySize(Spreads) - start;
      for(int i=0;i<newSize;i++)
        {
         Spreads[i] = Spreads[i+start];
         SpreadTimes[i] = SpreadTimes[i+start];
        }
      ArrayResize(Spreads,newSize);
      ArrayResize(SpreadTimes,newSize);
     }
   int m = ArraySize(Spreads);
   if(m<=0) { SpreadMedian=spread; return; }
   SpreadMedian = ArrayMedian(Spreads,m);
  }

//+------------------------------------------------------------------+
//| 配列中央値計算                                                   |
//+------------------------------------------------------------------+
double ArrayMedian(double &arr[],int n)
  {
   if(n<=0) return(0);
   double tmp[];
   ArrayResize(tmp,n);
   for(int i=0;i<n;i++) tmp[i]=arr[i];
   ArraySort(tmp);
   if(n%2==1) return(tmp[n/2]);
   return(0.5*(tmp[n/2-1]+tmp[n/2]));
  }

//+------------------------------------------------------------------+
//| Step計算                                                         |
//+------------------------------------------------------------------+
double CalcStep(double spread_pips)
  {
   double step = StepFactor*MathMax(spread_pips,SpreadFloor);
   double minStep = 1.5*spread_pips;
   if(step<minStep) step=minStep;
   return(step);
  }

//+------------------------------------------------------------------+
//| pip値                                                            |
//+------------------------------------------------------------------+
double Pip()
  {
   if(Digits==3 || Digits==5) return(10*Point);
   return(Point);
  }

//+------------------------------------------------------------------+
//| 指定pipsをポイントへ                                             |
//+------------------------------------------------------------------+
double PipsFrom(double p)
  {
   return(p*Pip());
  }

//+------------------------------------------------------------------+
//| Lot正規化                                                        |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   double l = MathCeil(lot/LotStep)*LotStep;
   if(l<MinLot) l=MinLot;
   int lotDigits = (int)MathRound(-MathLog10(LotStep));
   return(NormalizeDouble(l,lotDigits));
  }

//+------------------------------------------------------------------+
//| 注文コメント生成                                                  |
//+------------------------------------------------------------------+
string BuildComment(string role,int idx)
  {
   return(StringFormat("%s%d-%s-%d",CommentTag,CycleID,role,idx));
  }

//+------------------------------------------------------------------+
//| シンボルハッシュ                                                  |
//+------------------------------------------------------------------+
int SymbolHash(string s)
  {
   int sum=0;
   for(int i=0;i<StringLen(s);i++) sum+=StringGetChar(s,i);
   return(sum%1000);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
