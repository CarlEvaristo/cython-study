import os
import websocket_code
from ftx_client_class import FtxClient
import threading
import pyximport
pyximport.install()

from RUN import order_execution, get_order_status, fill_spread_array

# ------------ VARIABLES ----------------------------------
coin = "TRU"
API_1 = os.environ.get("API_1")
SECRET_1 = os.environ.get("SECRET_1")
sub = "1"
# ----------------------------------------------------------


if __name__ == "__main__":
    client = FtxClient(api_key=API_1, api_secret=SECRET_1, subaccount_name=sub)

    ws = websocket_code.FtxWebsocketClient(api=API_1, secret=SECRET_1, subaccount=sub)
    try:
        ws.connect()
        print("Connected to FTX websocket")
    except:
        print(f"WEBSOCKET ERROR. STARTING RETRY WEBSOCKET CONNECT.")

    thread1 = threading.Thread(target=order_execution, args=(coin, client))
    thread2 = threading.Thread(target=get_order_status, args=(ws,))
    thread3 = threading.Thread(target=fill_spread_array, args=(ws, coin))

    thread1.start()
    thread2.start()
    thread3.start()

    thread1.join()
    thread2.join()
    thread3.join()
