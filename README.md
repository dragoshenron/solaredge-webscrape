# solaredge-webscrape
Bash script to automatically download power optimizer data from Solaredge web portal.

This is an alpha version but it's working "good enough".
It's not user friendly and - by design - is based only a single plain bash script.

Briefly, the script
- create a cookie file with the authorisation token for the solaredge portal
- download all the data from the power optimizers of the specified site. The data are: Current Energy Voltage PowerBox%20Voltage Power
- optionally, the script can download data from a different day (full 24 hours only)
- the script is parsing the data and save (optionally) a local file in JSON and Line Protocol format
- the script is also posting (optionally) the data on an influxDB instance

You have to edit some parameters to fit your own site.
In particular, you have to get the requesterId from the Google Chrome Developer Tools. This is a one-time operation.

You are more than welcome to submit pull requests. This README needs definitely improvements :)

#TODO
#automatic requesterId retrieval
#output in CSV
