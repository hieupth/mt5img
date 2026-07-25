//+------------------------------------------------------------------+
//|                                                 AutoTradeBot.mq5 |
//| Paper-first autotrade loop for the MT5 API V1 decision contract. |
//+------------------------------------------------------------------+
#property strict
#property version   "1.000"
#property description "Polls trade decisions from the API, applies local guards, and reports paper/live status."

#include <Trade/Trade.mqh>

input string InpApiBaseUrl = "http://host.docker.internal:8000";
input string InpApiKey = "";
input int    InpPollSeconds = 30;
input string InpSymbols = "";              // Empty = current chart symbol. Comma/semicolon separated.
input long   InpMagicNumber = 26072301;
input bool   InpPaperMode = true;
input bool   InpEnableLiveTrading = false; // Real orders require InpPaperMode=false and this=true.
input int    InpMaxSpreadPoints = 50;
input int    InpMaxOpenPositionsPerSymbol = 1;
input double InpFixedLotSize = 0.01;
input int    InpApiTimeoutMs = 5000;
input int    InpStatusEveryPoll = 1;

CTrade g_trade;
string g_symbols[];

struct TradeDecision
{
   string decision_id;
   string symbol;
   string timeframe;
   string bar_time;
   string action;
   string side;
   string reason;
   double confidence;
   string expires_at;
   bool paper_only;
};

string Trim(const string value)
{
   string result = value;
   StringTrimLeft(result);
   StringTrimRight(result);
   return result;
}

string JsonEscape(const string value)
{
   string result = value;
   StringReplace(result, "\\", "\\\\");
   StringReplace(result, "\"", "\\\"");
   StringReplace(result, "\r", "\\r");
   StringReplace(result, "\n", "\\n");
   StringReplace(result, "\t", "\\t");
   return result;
}

string UrlEncode(const string value)
{
   string result = "";
   for(int i = 0; i < StringLen(value); i++)
   {
      ushort ch = StringGetCharacter(value, i);
      bool safe = (ch >= 'A' && ch <= 'Z') ||
                  (ch >= 'a' && ch <= 'z') ||
                  (ch >= '0' && ch <= '9') ||
                  ch == '-' || ch == '_' || ch == '.' || ch == '~';
      if(safe)
         result += ShortToString(ch);
      else if(ch == ' ')
         result += "%20";
      else
         result += StringFormat("%%%02X", (int)ch);
   }
   return result;
}

string BaseUrl()
{
   string url = Trim(InpApiBaseUrl);
   while(StringLen(url) > 0 && StringSubstr(url, StringLen(url) - 1, 1) == "/")
      url = StringSubstr(url, 0, StringLen(url) - 1);
   return url;
}

bool HttpRequestJson(const string method, const string url, const string payload, string &response, int &http_status)
{
   char data[];
   char result[];
   string result_headers = "";
   string headers = "Content-Type: application/json\r\n";
   if(InpApiKey != "")
      headers += "Authorization: Bearer " + InpApiKey + "\r\n";

   int bytes = StringToCharArray(payload, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(bytes > 0)
      ArrayResize(data, bytes - 1);

   ResetLastError();
   http_status = WebRequest(method, url, headers, InpApiTimeoutMs, data, result, result_headers);
   if(http_status == -1)
   {
      response = "WebRequest error=" + IntegerToString(GetLastError());
      return false;
   }

   response = CharArrayToString(result, 0, ArraySize(result), CP_UTF8);
   return (http_status >= 200 && http_status < 300);
}

int SkipWhitespace(const string text, int pos)
{
   while(pos < StringLen(text))
   {
      ushort ch = StringGetCharacter(text, pos);
      if(ch != ' ' && ch != '\n' && ch != '\r' && ch != '\t')
         break;
      pos++;
   }
   return pos;
}

bool JsonValue(const string json, const string key, string &value)
{
   string needle = "\"" + key + "\":";
   int pos = StringFind(json, needle);
   if(pos < 0)
      return false;

   pos = SkipWhitespace(json, pos + StringLen(needle));
   if(pos >= StringLen(json))
      return false;

   if(StringGetCharacter(json, pos) == '"')
   {
      pos++;
      string parsed = "";
      bool escaped = false;
      for(int i = pos; i < StringLen(json); i++)
      {
         ushort ch = StringGetCharacter(json, i);
         if(escaped)
         {
            parsed += ShortToString(ch);
            escaped = false;
            continue;
         }
         if(ch == '\\')
         {
            escaped = true;
            continue;
         }
         if(ch == '"')
         {
            value = parsed;
            return true;
         }
         parsed += ShortToString(ch);
      }
      return false;
   }

   int end = pos;
   while(end < StringLen(json))
   {
      ushort ch = StringGetCharacter(json, end);
      if(ch == ',' || ch == '}')
         break;
      end++;
   }
   value = Trim(StringSubstr(json, pos, end - pos));
   return true;
}

bool ParseDecision(const string json, TradeDecision &decision)
{
   string value = "";
   decision.decision_id = "";
   decision.symbol = "";
   decision.timeframe = "M1";
   decision.bar_time = "";
   decision.action = "hold";
   decision.side = "none";
   decision.reason = "";
   decision.confidence = 0.0;
   decision.expires_at = "";
   decision.paper_only = true;

   if(JsonValue(json, "decision_id", value))
      decision.decision_id = value;
   if(JsonValue(json, "symbol", value))
      decision.symbol = value;
   if(JsonValue(json, "timeframe", value))
      decision.timeframe = value;
   if(JsonValue(json, "bar_time", value) && value != "null")
      decision.bar_time = value;
   if(JsonValue(json, "action", value))
      decision.action = value;
   if(JsonValue(json, "side", value))
      decision.side = value;
   if(JsonValue(json, "reason", value))
      decision.reason = value;
   if(JsonValue(json, "confidence", value))
      decision.confidence = StringToDouble(value);
   if(JsonValue(json, "expires_at", value))
      decision.expires_at = value;
   if(JsonValue(json, "paper_only", value))
      decision.paper_only = (value == "true" || value == "1");

   return (decision.symbol != "" && decision.action != "");
}

datetime ParseIsoTime(string value)
{
   StringReplace(value, "T", " ");
   StringReplace(value, "Z", "");
   StringReplace(value, "-", ".");
   int plus_pos = StringFind(value, "+");
   if(plus_pos > 0)
      value = StringSubstr(value, 0, plus_pos);
   return StringToTime(value);
}

bool IsExpired(const string expires_at)
{
   datetime expires = ParseIsoTime(expires_at);
   if(expires <= 0)
      return true;
   return TimeCurrent() > expires;
}

bool LoadSymbols()
{
   string raw = Trim(InpSymbols);
   if(raw == "")
      raw = _Symbol;
   StringReplace(raw, ";", ",");

   string parts[];
   int count = StringSplit(raw, ',', parts);
   ArrayResize(g_symbols, 0);

   for(int i = 0; i < count; i++)
   {
      string symbol = Trim(parts[i]);
      if(symbol == "")
         continue;

      int index = ArraySize(g_symbols);
      ArrayResize(g_symbols, index + 1);
      g_symbols[index] = symbol;
      SymbolSelect(symbol, true);
   }

   return ArraySize(g_symbols) > 0;
}

int CurrentSpread(const string symbol, double &bid, double &ask)
{
   MqlTick tick;
   bid = 0.0;
   ask = 0.0;
   if(!SymbolInfoTick(symbol, tick))
      return -1;

   bid = tick.bid;
   ask = tick.ask;

   long spread = 0;
   if(SymbolInfoInteger(symbol, SYMBOL_SPREAD, spread))
      return (int)spread;

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0)
      return -1;
   return (int)MathRound((ask - bid) / point);
}

int CountManagedPositions(const string symbol, string &position_side)
{
   int buy_count = 0;
   int sell_count = 0;
   position_side = "none";

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY)
         buy_count++;
      else if(type == POSITION_TYPE_SELL)
         sell_count++;
   }

   if(buy_count > 0 && sell_count == 0)
      position_side = "buy";
   else if(sell_count > 0 && buy_count == 0)
      position_side = "sell";

   return buy_count + sell_count;
}

bool CanOpenSide(const string symbol, const string side, string &reason)
{
   long mode = SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED)
   {
      reason = "symbol_trade_disabled";
      return false;
   }
   if(mode == SYMBOL_TRADE_MODE_CLOSEONLY)
   {
      reason = "symbol_close_only";
      return false;
   }
   if(side == "buy" && mode == SYMBOL_TRADE_MODE_SHORTONLY)
   {
      reason = "symbol_short_only";
      return false;
   }
   if(side == "sell" && mode == SYMBOL_TRADE_MODE_LONGONLY)
   {
      reason = "symbol_long_only";
      return false;
   }
   return true;
}

bool FetchDecision(const string symbol, TradeDecision &decision, string &error_text)
{
   string position_side = "none";
   CountManagedPositions(symbol, position_side);

   string url = BaseUrl() + "/api/v1/mt5/trade-decisions/" + UrlEncode(symbol) +
                "?broker=" + UrlEncode(AccountInfoString(ACCOUNT_SERVER)) +
                "&timeframe=M1&position_side=" + UrlEncode(position_side);
   string response = "";
   int status = 0;
   if(!HttpRequestJson("GET", url, "", response, status))
   {
      error_text = "decision_http_status=" + IntegerToString(status) + " response=" + response;
      return false;
   }

   if(!ParseDecision(response, decision))
   {
      error_text = "decision_parse_failed response=" + response;
      return false;
   }

   return true;
}

bool PostStatus(
   const string symbol,
   const TradeDecision &decision,
   const string result,
   const string last_error
)
{
   double bid = 0.0;
   double ask = 0.0;
   int spread = CurrentSpread(symbol, bid, ask);
   string position_side = "none";
   int position_count = CountManagedPositions(symbol, position_side);
   string broker = AccountInfoString(ACCOUNT_SERVER);
   string account = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   bool paper = (InpPaperMode || !InpEnableLiveTrading || decision.paper_only);
   string paper_json = paper ? "true" : "false";

   string payload = "{";
   payload += "\"source\":\"mt5-autotrade\",";
   payload += "\"broker\":\"" + JsonEscape(broker) + "\",";
   payload += "\"account\":\"" + JsonEscape(account) + "\",";
   payload += "\"symbol\":\"" + JsonEscape(symbol) + "\",";
   payload += "\"timeframe\":\"M1\",";
   payload += "\"decision_id\":\"" + JsonEscape(decision.decision_id) + "\",";
   payload += "\"action\":\"" + JsonEscape(decision.action) + "\",";
   payload += "\"side\":\"" + JsonEscape(decision.side) + "\",";
   payload += "\"result\":\"" + JsonEscape(result) + "\",";
   payload += "\"paper\":" + paper_json + ",";
   payload += "\"reason\":\"" + JsonEscape(decision.reason) + "\",";
   payload += "\"last_error\":\"" + JsonEscape(last_error) + "\",";
   payload += "\"position_count\":" + IntegerToString(position_count) + ",";
   payload += "\"spread\":" + IntegerToString(spread) + ",";
   payload += "\"bid\":" + DoubleToString(bid, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)) + ",";
   payload += "\"ask\":" + DoubleToString(ask, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
   payload += "}";

   string url = BaseUrl() + "/api/v1/mt5/trade-status";
   string response = "";
   int status = 0;
   if(!HttpRequestJson("POST", url, payload, response, status))
   {
      PrintFormat("[autotrade] status post failed symbol=%s status=%d response=%s", symbol, status, response);
      return false;
   }
   return true;
}

string ExecuteOpen(const string symbol, const TradeDecision &decision, string &last_error)
{
   string guard = "";
   if(!CanOpenSide(symbol, decision.side, guard))
      return "skipped_" + guard;

   string position_side = "none";
   int position_count = CountManagedPositions(symbol, position_side);
   if(position_count >= InpMaxOpenPositionsPerSymbol)
      return "skipped_position_limit";

   if(decision.side != "buy" && decision.side != "sell")
      return "skipped_invalid_side";

   if(InpPaperMode || decision.paper_only)
      return "would_open_" + decision.side;

   if(!InpEnableLiveTrading)
      return "blocked_live_disabled";

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   bool ok = false;
   string comment = "api_decision:" + decision.decision_id;
   if(decision.side == "buy")
      ok = g_trade.Buy(InpFixedLotSize, symbol, 0.0, 0.0, 0.0, comment);
   else
      ok = g_trade.Sell(InpFixedLotSize, symbol, 0.0, 0.0, 0.0, comment);

   if(!ok)
   {
      last_error = "trade_retcode=" + IntegerToString((int)g_trade.ResultRetcode()) +
                   " desc=" + g_trade.ResultRetcodeDescription();
      return "order_failed";
   }
   return "opened_" + decision.side;
}

string ExecuteClose(const string symbol, const TradeDecision &decision, string &last_error)
{
   string position_side = "none";
   int position_count = CountManagedPositions(symbol, position_side);
   if(position_count <= 0)
      return "skipped_no_position";

   if(InpPaperMode || decision.paper_only)
      return "would_close_" + position_side;

   if(!InpEnableLiveTrading)
      return "blocked_live_disabled";

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      if(g_trade.PositionClose(ticket))
         closed++;
      else
      {
         last_error = "close_retcode=" + IntegerToString((int)g_trade.ResultRetcode()) +
                      " desc=" + g_trade.ResultRetcodeDescription();
         return "close_failed";
      }
   }

   return "closed_" + IntegerToString(closed);
}

string ProcessDecision(const string symbol, const TradeDecision &decision, string &last_error)
{
   if(decision.symbol != symbol)
      return "skipped_symbol_mismatch";
   if(decision.timeframe != "M1")
      return "skipped_timeframe_mismatch";
   if(decision.action != "hold" && decision.action != "open" && decision.action != "close")
      return "skipped_invalid_action";
   if(IsExpired(decision.expires_at))
      return "skipped_expired_decision";
   if(!SymbolSelect(symbol, true))
      return "skipped_symbol_select_failed";

   double bid = 0.0;
   double ask = 0.0;
   int spread = CurrentSpread(symbol, bid, ask);
   if(spread < 0)
      return "skipped_no_tick";
   if(InpMaxSpreadPoints > 0 && spread > InpMaxSpreadPoints)
      return "skipped_spread_limit";

   if(decision.action == "hold")
      return "hold";
   if(decision.action == "open")
      return ExecuteOpen(symbol, decision, last_error);
   if(decision.action == "close")
      return ExecuteClose(symbol, decision, last_error);

   return "skipped_unknown";
}

void PollSymbol(const string symbol)
{
   TradeDecision decision;
   string error_text = "";
   if(!FetchDecision(symbol, decision, error_text))
   {
      PrintFormat("[autotrade] decision fetch failed symbol=%s %s", symbol, error_text);
      decision.symbol = symbol;
      decision.timeframe = "M1";
      decision.action = "hold";
      decision.side = "none";
      decision.reason = "decision_fetch_failed";
      decision.decision_id = "";
      if(InpStatusEveryPoll)
         PostStatus(symbol, decision, "decision_fetch_failed", error_text);
      return;
   }

   string last_error = "";
   string result = ProcessDecision(symbol, decision, last_error);
   PrintFormat(
      "[autotrade] symbol=%s decision=%s action=%s side=%s result=%s reason=%s confidence=%.4f",
      symbol,
      decision.decision_id,
      decision.action,
      decision.side,
      result,
      decision.reason,
      decision.confidence
   );

   if(InpStatusEveryPoll || result != "hold")
      PostStatus(symbol, decision, result, last_error);
}

void PollAllSymbols()
{
   for(int i = 0; i < ArraySize(g_symbols); i++)
      PollSymbol(g_symbols[i]);
}

int OnInit()
{
   if(!LoadSymbols())
   {
      Print("[autotrade] no symbols configured");
      return INIT_FAILED;
   }

   int poll_seconds = InpPollSeconds;
   if(poll_seconds < 5)
      poll_seconds = 5;

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   EventSetTimer(poll_seconds);

   PrintFormat("[autotrade] initialized symbols=%d paper=%s live_enabled=%s poll_seconds=%d api=%s",
               ArraySize(g_symbols),
               InpPaperMode ? "true" : "false",
               InpEnableLiveTrading ? "true" : "false",
               poll_seconds,
               BaseUrl());

   PollAllSymbols();
   return INIT_SUCCEEDED;
}

void OnTimer()
{
   PollAllSymbols();
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   PrintFormat("[autotrade] stopped reason=%d", reason);
}
