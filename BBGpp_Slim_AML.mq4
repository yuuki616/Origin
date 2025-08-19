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
int    CycleID=0;
int    symbolHash=0;
int    MagicGrid=0;
Regime regime=REGIME_NORMAL;
Cycle  cycle=CYCLE_RUNNING;
AMLState aml_state=AML_OFF;
int    lastTimerTick=0;
double StopLevel=0;
double FreezeLevel=0;
double LotStep=0;
double MinLot=0;
int    lastSpread=0;          // 直近スプレッド(ポイント)
// スプレッド履歴
int      Spreads[];
datetime SpreadTimes[];
// 操作回数制限
datetime opsWindowStart=0;
int      opsCount=0;

//+------------------------------------------------------------------+
//| 初期化                                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   symbolHash = SymbolHash(Symbol());
   MagicGrid = MagicBase + 10 + symbolHash;
   AnchorPrice = NormalizeDouble( (Ask+Bid)/2, Digits );
   lastSpread = (int)MarketInfo(Symbol(),MODE_SPREAD);
   ArrayResize(Spreads,1);
   ArrayResize(SpreadTimes,1);
   Spreads[0] = lastSpread;
   SpreadTimes[0] = TimeCurrent();
   SpreadMedian = lastSpread;
   double spread_pips_init = lastSpread * Point / Pip();
   Step = CalcStep(spread_pips_init);
   StopLevel  = MarketInfo(Symbol(),MODE_STOPLEVEL)  * Point;
   FreezeLevel= MarketInfo(Symbol(),MODE_FREEZELEVEL)* Point;
   LotStep    = MarketInfo(Symbol(),MODE_LOTSTEP);
   MinLot     = MarketInfo(Symbol(),MODE_MINLOT);
   Print("Init: Step=",Step," Pip=",Pip()," StopLevel=",StopLevel/Point,
         " FreezeLevel=",FreezeLevel/Point);
   EventSetMillisecondTimer(TimerInterval_ms);
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
   lastSpread = (int)((Ask-Bid)/Point);
   UpdateSpreadMedian(lastSpread);
  }

//+------------------------------------------------------------------+
//| タイマー実行                                                     |
//+------------------------------------------------------------------+
void OnTimer()
  {
   double spread_pips = lastSpread * Point / Pip();
   Step = CalcStep(spread_pips);

   int held=0,pending=0;
   CountOrders(held,pending);
   // 保有が上限に達した場合は保留を全取消
   if(held>=MaxUnits)
     {
      if(pending>0) CancelPendingOrders(pending);
      return;
     }

   int allowedPending = MaxUnits - held;
   if(pending>allowedPending)
     {
      // 過剰な保留注文を一度に整理
      CancelPendingOrders(pending-allowedPending);
      return;
     }

   if(!SpreadGate(lastSpread)) return;
   if(!TimeGate()) return;

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
      bool needBuy = (buyPrice < Ask && !FindPendingPrice(buyPrice,OP_BUYLIMIT));
      bool needSell= (sellPrice> Bid && !FindPendingPrice(sellPrice,OP_SELLLIMIT));

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
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MagicGrid) continue;
      int type=OrderType();
      if(type==OP_BUY || type==OP_SELL) held++;
      if(type==OP_BUYLIMIT || type==OP_SELLLIMIT) pending++;
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
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MagicGrid) continue;
      int type=OrderType();
      if(type==OP_BUYLIMIT || type==OP_SELLLIMIT)
        {
         int ticket=OrderTicket();
         DeleteWithRetry(ticket);
         count--;
        }
     }
  }

//+------------------------------------------------------------------+
//| 指定価格の保留注文有無                                            |
//+------------------------------------------------------------------+
bool FindPendingPrice(double price,int type)
  {
   for(int i=OrdersTotal()-1;i>=0;i--)
     {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES)) continue;
      if(OrderSymbol()!=Symbol() || OrderMagicNumber()!=MagicGrid) continue;
      if(OrderType()==type && MathAbs(OrderOpenPrice()-price)<=Point)
         return(true);
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

   string comment = StringFormat("%s%d-G-%d",CommentTag,CycleID,level);
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
//| SpreadGate                                                       |
//+------------------------------------------------------------------+
bool SpreadGate(int spread)
  {
   double cap = SpreadMedian*SpreadCapMult;
   if(spread>cap) return(false);
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
void UpdateSpreadMedian(int spread)
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
double ArrayMedian(int &arr[],int n)
  {
   if(n<=0) return(0);
   int tmp[];
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
