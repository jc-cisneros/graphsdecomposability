Mart Demirer, Francis X. Diebold, Laura Liu, and Kamil Yilmaz,
"Estimating Global Bank Network Connectedness", Journal of Applied
Econometrics, Vol. 33, No. 1, 2018, pp. 1-15.
	
The data used in this paper combine two sources. The data for stock
prices are from Thomson Reuters, and the data for bond prices are from
Bloomberg. The raw data consist of daily high, low, open and close
prices, from which we calculate daily volatility series for each bank
stock and government bond according to the formula in equation (6) in
the main text. The series in ddly-data.csv are the calculated daily
range volatility series for the assets we include in our paper.

The data consist of 2,676 observations, spanning the period 2003-2014.
There are 106 variables.  The first 96 columns contain the data for
bank stocks. The list of banks we analyze in the paper can be found in
the online appendix. The bank names in the first row are Reuters
Tickers. We provided corresponding bank names in the data appendix. The
last 10 columns contain the 10-year government bond data for the
following countries

US_b  : United States of America
UK_b  : United Kingdom
GER_b : Germany    
FRA_b : France
ITA_b : Italy    
ESP_b : Spain    
GRC_b : Greece    
JPN_b : Japan    
CAN_b : Canada    

The file ddly-data.csv is an ASCII file in DOS format. It is zipped in
the file ddly-data.zip. Unix/Linux users should use "unzip -a".

Kamil Yilmaz 
kyilmaz [AT] ku.edu.tr
