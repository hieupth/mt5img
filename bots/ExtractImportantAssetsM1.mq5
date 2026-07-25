//+------------------------------------------------------------------+
//|                                      ExtractImportantAssetsM1.mq5 |
//| Export M1 OHLCV CSV files for major tradable assets.             |
//|                                                                  |
//| Output inside the MT5 container:                                 |
//|   /config/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Files/   |
//|     mt5_exports/*.csv                                            |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Exports recent M1 OHLCV bars for important forex, metals, energy, index, and crypto assets."

input int  InpBarsToExport    = 1440; // Recent M1 bars per symbol
input bool InpUseCommonFiles  = false;
input int  InpRepeatSeconds   = 60;   // 0 = use InpRepeatMinutes/run once
input int  InpRepeatMinutes   = 0;    // Legacy repeat interval
input string InpOutputFolder  = "mt5_exports";
input string InpExtraAssetSpecs = ""; // Optional: TARGET:ALIAS1|ALIAS2;TARGET2:ALIAS
input int InpDebugLogMinIntervalSeconds = 60;
input int InpDebugLogMaxBytes = 1048576;

int g_file_flags = FILE_WRITE | FILE_CSV | FILE_ANSI;
bool g_export_running = false;
string g_last_debug_message = "";
datetime g_last_debug_time = 0;
int g_suppressed_debug_count = 0;

void DebugLog(const string message)
{
   datetime now = TimeCurrent();
   int min_interval = InpDebugLogMinIntervalSeconds;
   if(min_interval < 1)
      min_interval = 1;

   if(message == g_last_debug_message && g_last_debug_time > 0 && (now - g_last_debug_time) < min_interval)
   {
      g_suppressed_debug_count++;
      return;
   }

   int handle = FileOpen("extract_debug.log", FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(handle == INVALID_HANDLE)
      return;

   int max_bytes = InpDebugLogMaxBytes;
   if(max_bytes > 0 && FileSize(handle) > (ulong)max_bytes)
   {
      FileClose(handle);
      FileDelete("extract_debug.log");
      handle = FileOpen("extract_debug.log", FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
      if(handle == INVALID_HANDLE)
         return;
   }

   FileSeek(handle, 0, SEEK_END);
   if(g_suppressed_debug_count > 0)
   {
      FileWrite(handle, TimeToString(now, TIME_DATE | TIME_SECONDS) +
                " previous message repeated " + IntegerToString(g_suppressed_debug_count) + " times");
      g_suppressed_debug_count = 0;
   }
   FileWrite(handle, TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + " " + message);
   FileClose(handle);
   g_last_debug_message = message;
   g_last_debug_time = now;
}

struct AssetResult
{
   string target;
   string symbol;
   int    bars;
   string status;
   string file_name;
};

string Trim(const string value)
{
   string result = value;
   StringTrimLeft(result);
   StringTrimRight(result);
   return result;
}

string Upper(const string value)
{
   string result = value;
   StringToUpper(result);
   return result;
}

string NormalizeSymbol(const string value)
{
   string upper = Upper(value);
   string result = "";

   for(int i = 0; i < StringLen(upper); i++)
   {
      ushort ch = StringGetCharacter(upper, i);
      if((ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9'))
         result += ShortToString(ch);
   }

   return result;
}

string SafeFilePart(const string value)
{
   string result = value;
   StringReplace(result, "\\", "_");
   StringReplace(result, "/", "_");
   StringReplace(result, ":", "_");
   StringReplace(result, "*", "_");
   StringReplace(result, "?", "_");
   StringReplace(result, "\"", "_");
   StringReplace(result, "<", "_");
   StringReplace(result, ">", "_");
   StringReplace(result, "|", "_");
   StringReplace(result, " ", "_");
   return result;
}

string DefaultAssetSpecs()
{
   string specs = "";

   specs += "EURUSD:EURUSD;";
   specs += "GBPUSD:GBPUSD;";
   specs += "USDJPY:USDJPY;";
   specs += "USDCHF:USDCHF;";
   specs += "USDCAD:USDCAD;";
   specs += "AUDUSD:AUDUSD;";
   specs += "NZDUSD:NZDUSD;";
   specs += "EURJPY:EURJPY;";
   specs += "GBPJPY:GBPJPY;";
   specs += "XAUUSD:XAUUSD|GOLD;";
   specs += "XAGUSD:XAGUSD|SILVER;";
   specs += "USOIL:USOIL|WTI|XTIUSD|OIL.WTI;";
   specs += "UKOIL:UKOIL|BRENT|XBRUSD|OIL.BRENT;";
   specs += "US30:US30|DJ30|DJI|DOW|WS30;";
   specs += "US500:US500|SPX500|SP500|S&P500|USA500;";
   specs += "NAS100:NAS100|NASDAQ100|USTEC|US100|NDX100;";
   specs += "GER40:GER40|DE40|DAX40|GER30|DAX;";
   specs += "UK100:UK100|FTSE100;";
   specs += "JP225:JP225|JPN225|NIKKEI225;";
   specs += "BTCUSD:BTCUSD|BTCUSDT|BITCOIN;";
   specs += "ETHUSD:ETHUSD|ETHUSDT|ETHEREUM";

   string extra_specs = Trim(InpExtraAssetSpecs);
   if(extra_specs != "")
   {
      if(StringSubstr(specs, StringLen(specs) - 1, 1) != ";")
         specs += ";";
      specs += extra_specs;
   }

   return specs;
}

bool AliasMatchesSymbol(const string alias, const string symbol)
{
   string normalized_alias = NormalizeSymbol(alias);
   string normalized_symbol = NormalizeSymbol(symbol);

   if(normalized_alias == "" || normalized_symbol == "")
      return false;

   if(normalized_symbol == normalized_alias)
      return true;

   int alias_len = StringLen(normalized_alias);
   int symbol_len = StringLen(normalized_symbol);

   if(symbol_len > alias_len)
   {
      if(StringSubstr(normalized_symbol, 0, alias_len) == normalized_alias)
         return true;

      if(StringSubstr(normalized_symbol, symbol_len - alias_len, alias_len) == normalized_alias)
         return true;
   }

   return (StringFind(normalized_symbol, normalized_alias) >= 0);
}

int MatchScore(const string alias, const string symbol)
{
   string normalized_alias = NormalizeSymbol(alias);
   string normalized_symbol = NormalizeSymbol(symbol);

   if(normalized_symbol == normalized_alias)
      return StringLen(symbol);

   int alias_len = StringLen(normalized_alias);
   int symbol_len = StringLen(normalized_symbol);

   if(symbol_len > alias_len)
   {
      if(StringSubstr(normalized_symbol, 0, alias_len) == normalized_alias)
         return 100 + StringLen(symbol);

      if(StringSubstr(normalized_symbol, symbol_len - alias_len, alias_len) == normalized_alias)
         return 200 + StringLen(symbol);
   }

   if(StringFind(normalized_symbol, normalized_alias) >= 0)
      return 300 + StringLen(symbol);

   return 2147483647;
}

string FindBrokerSymbol(const string aliases_text)
{
   string aliases[];
   int alias_count = StringSplit(aliases_text, '|', aliases);
   string best_symbol = "";
   int best_score = 2147483647;

   for(int pass = 0; pass < 2; pass++)
   {
      bool selected_only = (pass == 0);
      int total = SymbolsTotal(selected_only);

      for(int i = 0; i < total; i++)
      {
         string symbol = SymbolName(i, selected_only);

         for(int a = 0; a < alias_count; a++)
         {
            string alias = Trim(aliases[a]);
            if(!AliasMatchesSymbol(alias, symbol))
               continue;

            int score = MatchScore(alias, symbol);
            if(score < best_score)
            {
               best_score = score;
               best_symbol = symbol;
            }
         }
      }

      if(best_symbol != "")
         break;
   }

   return best_symbol;
}

bool CopyM1RatesWithRetry(const string symbol, MqlRates &rates[])
{
   ArrayFree(rates);
   ResetLastError();

   for(int attempt = 1; attempt <= 8; attempt++)
   {
      int bars_to_export = InpBarsToExport;
      if(bars_to_export < 1)
         bars_to_export = 1;

      int copied = CopyRates(symbol, PERIOD_M1, 0, bars_to_export, rates);
      if(copied > 0)
         return true;

      PrintFormat("[extract] Waiting for M1 history: %s attempt=%d error=%d",
                  symbol, attempt, GetLastError());
      Sleep(1500);
      ResetLastError();
   }

   return false;
}

int ExportSymbolCsv(const string target, const string symbol, string &file_name)
{
   MqlRates rates[];
   if(!CopyM1RatesWithRetry(symbol, rates))
      return 0;

   int copied = ArraySize(rates);
   file_name = InpOutputFolder + "/" + SafeFilePart(target) + "_" + SafeFilePart(symbol) + "_M1.csv";
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   int handle = FileOpen(file_name, g_file_flags, ',');
   if(handle == INVALID_HANDLE)
   {
      PrintFormat("[extract] Could not open %s, error=%d", file_name, GetLastError());
      return -1;
   }

   FileWrite(handle,
             "time",
             "symbol",
             "timeframe",
             "open",
             "high",
             "low",
             "close",
             "tick_volume",
             "spread",
             "real_volume");

   bool newest_first = (copied > 1 && rates[0].time > rates[copied - 1].time);
   int start = newest_first ? copied - 1 : 0;
   int stop = newest_first ? -1 : copied;
   int step = newest_first ? -1 : 1;

   for(int i = start; i != stop; i += step)
   {
      FileWrite(handle,
                TimeToString(rates[i].time, TIME_DATE | TIME_MINUTES),
                symbol,
                "M1",
                DoubleToString(rates[i].open, digits),
                DoubleToString(rates[i].high, digits),
                DoubleToString(rates[i].low, digits),
                DoubleToString(rates[i].close, digits),
                (long)rates[i].tick_volume,
                rates[i].spread,
                (long)rates[i].real_volume);
   }

   FileClose(handle);
   return copied;
}

void WriteManifest(const AssetResult &results[])
{
   string manifest_name = InpOutputFolder + "/manifest.csv";
   int handle = FileOpen(manifest_name, g_file_flags, ',');
   if(handle == INVALID_HANDLE)
   {
      PrintFormat("[extract] Could not open manifest %s, error=%d", manifest_name, GetLastError());
      return;
   }

   FileWrite(handle, "exported_at", "target", "broker_symbol", "timeframe", "bars", "status", "file");

   string exported_at = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
   for(int i = 0; i < ArraySize(results); i++)
   {
      FileWrite(handle,
                exported_at,
                results[i].target,
                results[i].symbol,
                "M1",
                results[i].bars,
                results[i].status,
                results[i].file_name);
   }

   FileClose(handle);
}

void RunExport()
{
   if(g_export_running)
   {
      DebugLog("RunExport skipped because previous run is still active");
      return;
   }

   g_export_running = true;
   DebugLog("RunExport start write_csv=true" +
            " repeat_seconds=" + IntegerToString(InpRepeatSeconds) +
            " repeat_minutes=" + IntegerToString(InpRepeatMinutes));

   if(InpUseCommonFiles)
      g_file_flags = FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON;
   else
      g_file_flags = FILE_WRITE | FILE_CSV | FILE_ANSI;

   FolderCreate(InpOutputFolder, InpUseCommonFiles ? FILE_COMMON : 0);

   string specs[];
   int spec_count = StringSplit(DefaultAssetSpecs(), ';', specs);
   AssetResult results[];
   ArrayResize(results, spec_count);

   PrintFormat("[extract] Starting M1 export for %d asset specs, bars=%d", spec_count, InpBarsToExport);

   for(int i = 0; i < spec_count; i++)
   {
      string spec = Trim(specs[i]);
      int separator = StringFind(spec, ":");

      string target = separator >= 0 ? Trim(StringSubstr(spec, 0, separator)) : spec;
      string aliases = separator >= 0 ? Trim(StringSubstr(spec, separator + 1)) : spec;

      results[i].target = target;
      results[i].symbol = "";
      results[i].bars = 0;
      results[i].status = "not_found";
      results[i].file_name = "";

      string symbol = FindBrokerSymbol(aliases);
      if(symbol == "")
      {
         DebugLog("No symbol found target=" + target + " aliases=" + aliases);
         PrintFormat("[extract] No broker symbol found for target=%s aliases=%s", target, aliases);
         continue;
      }

      if(!SymbolSelect(symbol, true))
      {
         DebugLog("SymbolSelect failed target=" + target + " symbol=" + symbol);
         results[i].symbol = symbol;
         results[i].status = "select_failed";
         PrintFormat("[extract] Could not select symbol %s for target=%s", symbol, target);
         continue;
      }

      string file_name = "";
      int bars = ExportSymbolCsv(target, symbol, file_name);
      results[i].symbol = symbol;
      results[i].bars = bars > 0 ? bars : 0;
      results[i].file_name = file_name;
      results[i].status = bars > 0 ? "exported" : "export_failed";
      DebugLog("Export result target=" + target + " symbol=" + symbol +
               " status=" + results[i].status +
               " bars=" + IntegerToString(results[i].bars));

      PrintFormat("[extract] %s -> %s status=%s bars=%d file=%s",
                  target, symbol, results[i].status, results[i].bars, file_name);
   }

   WriteManifest(results);
   PrintFormat("[extract] Finished. Check %s/manifest.csv", InpOutputFolder);
   g_export_running = false;
}

int OnInit()
{
   DebugLog("OnInit");
   RunExport();

   if(InpRepeatSeconds > 0)
      EventSetTimer(InpRepeatSeconds);
   else if(InpRepeatMinutes > 0)
      EventSetTimer(InpRepeatMinutes * 60);
   else
      ExpertRemove();

   return INIT_SUCCEEDED;
}

void OnTimer()
{
   RunExport();
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   PrintFormat("[extract] Deinitialized. reason=%d", reason);
}
