//+------------------------------------------------------------------+
//|                                              TestExpert.mq5      |
//|                        Simple test EA for verifying MT5 Docker    |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("TestExpert initialized successfully");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Print("TestExpert deinitialized. Reason: ", reason);
}

void OnTick()
{
   Print("TestExpert tick received. Time: ", TimeCurrent());
}
