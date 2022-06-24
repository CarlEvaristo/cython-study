import requests
import time
import datetime
import numpy as np
from numpy import ndarray
import cython # changed int types to cython.int manually
# cimport numpy as np

# ------------ VARIABLES ----------------------------------
orderstatus: dict = {}
ticker: tuple[cython.double, cython.double] = (1.0, 2.0)
spread_array: ndarray = np.array([])
# ----------------------------------------------------------


def get_order_status(ws):
    global orderstatus
    while True:
        data: dict = ws.get_orders()
        if data != {}:
            orderstatus = list(data.items())[-1][1]
        time.sleep(0.001)


def fill_spread_array(ws, coin):
    global spread_array
    global ticker
    maximum_items: cython.int = 500
    # infinite loop: fill np array with spread data / delete old data
    while True:
        # calculate spread data
        spot: dict = ws.get_ticker(market=f"{coin.upper()}/USD")
        perp: dict = ws.get_ticker(market=f"{coin.upper()}-PERP")
        if (spot != {}) and (perp != {}):
            spread: cython.double = perp["ask"] - spot["bid"]
            spread_array = np.insert(spread_array, 0, [spread], axis=0)        # add spread data to np array
            spread_array = np.delete(spread_array, np.s_[maximum_items:])    # remove old items from np array
            ticker = (perp["bid"], perp["ask"], spot["bid"], spot["ask"])
        time.sleep(0.001)


def get_my_spot_bid():
    global spread_array
    global ticker
    minimum_items: cython.int = 500
    stdev_num: cython.int = 2
    my_bid: cython.double

    while spread_array.size < minimum_items:
        print("Waiting for sufficient spread data")
        time.sleep(0.001)

    # calculate spread's mean and std
    spread_mean: cython.double = spread_array.mean()
    spread_std: cython.double = spread_array.std()
    mean_plus_st_dev: cython.double = spread_mean + (spread_std * stdev_num)

    # get latest ticker
    # (perp["bid"], perp["ask"], spot["bid"], spot["ask"])
    spot_bid: cython.double = ticker[2]
    perp_ask: cython.double = ticker[1]
    perp_bid: cython.double = ticker[0] # WHEN PERP MARKET ORDER (SPOT BASED ON PERP_BID INSTEAD OF PERP_ASK) !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

    my_bid: cython.double = perp_ask - mean_plus_st_dev
    if my_bid > (perp_ask * 0.998):  # BASISPOINTS  0.2% --> was 1.005  --> 0.995  --> nu alleem fees (0.14% afgerond naar 0.2%) als bps  --> 1.002  --> 0.998
        my_bid = perp_ask * 0.998
    if my_bid >= spot_bid:
        my_bid = spot_bid
    return my_bid


def get_my_perp_ask(price_increment_perp):
    global ticker
    my_ask: cython.double
    # get latest ticker
    # (perp["bid"], perp["ask"], spot["bid"], spot["ask"])
    perp_bid: cython.double = ticker[0]
    perp_ask: cython.double = ticker[1]

    if perp_bid < (perp_ask - price_increment_perp):
        my_ask = perp_ask - price_increment_perp
    else:
        my_ask = perp_ask
    return my_ask


def order_execution(coin, client):
    time.sleep(2)
    global orderstatus
    global ticker

    coin = coin.upper()
    coin_spot = f"{coin}/USD"
    coin_perp = f"{coin}-PERP"

    # determine position size
    balance: list = client.get_balances()
    available_USD: cython.double = [item["free"] for item in balance if item["coin"] == "USD"][0]
    available_USD = (available_USD * 0.95) / 2  # takes 95% of subaccount and divides it 50/50 over spot/perp
    # num_batches = num_batches   # OLD CODE FOR BATCHES
    # available_USD_per_batch = (available_USD / num_batches)  # OLD CODE FOR BATCHES

    # determine SPOT's possible position size  --> WE MUST DETERMINE SPOT'S SIZE FIRST, AS SPOT SIZE IS BOUNDED BY SIZE INCREMENTS
    # OLD CODE FOR BATCHES
    # size = available_USD_per_batch / my_bid_price
    # size = available_USD / my_bid_price
    # "size-increment" of spot coin: the nr of decimals, etc.
    # minimum required SPOT size

    # get SPOT data
    spot_data: dict = requests.get(f'https://ftx.com/api/markets/{coin_spot}').json()
    price_increment_spot: cython.double = spot_data["result"]["priceIncrement"]
    size_increment: cython.double = spot_data["result"]["sizeIncrement"]
    spot_minProvideSize: cython.double = spot_data["result"]["minProvideSize"]

    # get price increment PERP
    price_increment_perp: cython.double = requests.get(f'https://ftx.com/api/markets/{coin_perp}').json()["result"]["priceIncrement"]

    price_per_incr: cython.double = get_my_spot_bid() * size_increment  # ---> PRICE PER INCREMENT!!!!!
    total_incr: cython.int = int(available_USD / price_per_incr)

    spot_size: cython.double = total_incr * size_increment
    print(f"{coin}: SPOT ORDER SIZE: {spot_size}")
    if spot_size < spot_minProvideSize:
        print(f"{coin}: INITIAL ORDER FAILED: BALANCE TOO LOW FOR MIN REQUIRED SIZE INCREMENT")
        # return "FAILED"

    # SPOT ORDER
    client.place_order(market=f"{coin_spot}", side="buy", price=get_my_spot_bid(), type="limit", size=spot_size, post_only=True, reduce_only=False)

    while orderstatus == {}:
        time.sleep(0.001)

    while orderstatus["status"] != "new":  # BELANGRIJK!!!!!!! EVEN WACHTEN TOT WEBSOCKET NEW ORDER BEVESTIGT
        time.sleep(0.001)

    while (orderstatus["filledSize"] != orderstatus["size"]):
        print(orderstatus)
        if (get_my_spot_bid() > (orderstatus["price"] + price_increment_spot)) or (get_my_spot_bid() < (orderstatus["price"] - price_increment_spot)) and \
                (orderstatus["status"] != "closed") and (orderstatus["filledSize"] != orderstatus["size"]):
            print(f"TIME SPOT ENTRY 0 = {datetime.datetime.now()}")
            if orderstatus["status"] != "closed":
                try:
                    client.cancel_order(order_id=orderstatus["id"])
                    while orderstatus["status"] != "closed":
                        time.sleep(0.001)
                except: pass

            print(f"TIME SPOT ENTRY 1 = {datetime.datetime.now()}")
        if (orderstatus["status"] == "closed") and (orderstatus["filledSize"] != orderstatus["size"]):
            client.place_order(market=f"{coin_spot}", side="buy", price=get_my_spot_bid(), type="limit", size=(orderstatus["size"] - orderstatus["filledSize"]), post_only=True, reduce_only=False)
            while orderstatus["status"] != "new":
                time.sleep(0.001)
            print(f"TIME SPOT ENTRY 2 = {datetime.datetime.now()}")

    # # PERP MARKET ORDER
    # perp_order = client.place_order(market=f"{coin_perp}", side="sell", price=0, type="market",size=spot_size, reduce_only=False)
    # time.sleep(2)
    # print(f"{coin}: PERP MARKET ORDER: {perp_order}")

    # PERP LIMIT ORDER
    client.place_order(market=f"{coin_perp}", side="sell", price=get_my_perp_ask(price_increment_perp), type="limit", size=spot_size, post_only=True, reduce_only=False)
    while orderstatus["status"] != "new":
        print("TEST WAIT 4 CONFIRMATION OF 1ST PERP LIMIT")
        time.sleep(0.001)

    while (orderstatus["filledSize"] != orderstatus["size"]):
        if (orderstatus["price"] != ticker[1]) and (orderstatus["status"] != "closed") and (orderstatus["filledSize"] != orderstatus["size"]):
            print(f"TIME PERP ENTRY 0 = {datetime.datetime.now()}")
            if orderstatus["status"] != "closed":
                try:
                    client.cancel_order(order_id=orderstatus["id"])
                    while orderstatus["status"] != "closed":
                        time.sleep(0.001)
                except: pass
            print(f"TIME PERP ENTRY 1 = {datetime.datetime.now()}")
        if (orderstatus["status"] == "closed") and (orderstatus["filledSize"] != orderstatus["size"]):
            client.place_order(market=f"{coin_perp}", side="sell",price=get_my_perp_ask(price_increment_perp),type="limit",size=(orderstatus["size"] - orderstatus["filledSize"]),post_only=True,reduce_only=False)
            while orderstatus["status"] != "new":
                time.sleep(0.001)
            print(f"TIME PERP ENTRY 2 = {datetime.datetime.now()}")
    #
    # return "SUCCESS"  # DIT GAAN NAAR SAMS EXIT ---> ONDERSTAANDE CODE IS MIJN EXIT
    print("TEST GA NAAR EXIT EXECUTION")
    exit_order_execution(coin, client, spot_size, price_increment_spot)


def my_spot_exit_price():
    global ticker
    my_spot_ask: cython.double
    # get latest ticker
    # (perp["bid"], perp["ask"], spot["bid"], spot["ask"])
    perp_bid: cython.double = ticker[0]
    perp_ask: cython.double = ticker[1]  # WHEN PERP MARKET EXIT (SPOT BASED ON PERP_ASK INSTEAD OF PERP_BID) !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    spot_ask: cython.double = ticker[3]

    if perp_bid > spot_ask:
        my_spot_ask = perp_bid
    else:
        my_spot_ask = spot_ask
    return my_spot_ask


def my_perp_exit_price(price_increment_perp):
    global ticker
    my_bid: cython.double
    # get latest ticker
    # (perp["bid"], perp["ask"], spot["bid"], spot["ask"])
    perp_bid: cython.double = ticker[0]
    perp_ask: cython.double = ticker[1]

    if perp_ask > (perp_bid + price_increment_perp):
        my_bid = perp_bid + price_increment_perp
    else:
        my_bid = perp_bid
    return my_bid


def exit_order_execution(coin, client, spot_size, price_increment_spot):
    global orderstatus
    global ticker    # (perp["bid"], perp["ask"], spot["bid"], spot["ask"])
    print("TEST ENTERED EXIT FUNCTION")
    coin = coin.upper()
    coin_spot = f"{coin}/USD"
    coin_perp = f"{coin}-PERP"

    # get price increment PERP
    price_increment_perp: cython.double = requests.get(f'https://ftx.com/api/markets/{coin_perp}').json()["result"]["priceIncrement"]

    # SPOT EXIT ORDER
    client.place_order(market=f"{coin_spot}", side="sell", price=my_spot_exit_price(), type="limit", size=spot_size, post_only=True, reduce_only=True)
    print("TEST PLACED SPOT EXIT ORDER")

    while orderstatus["status"] != "new":  # BELANGRIJK!!!!!!! EVEN WACHTEN TOT WEBSOCKET NEW ORDER BEVESTIGT
        time.sleep(0.001)
        print("TEST WAIT 4 CONFIRMATION OF SPOT EXIT ORDER")

    while (orderstatus["filledSize"] != orderstatus["size"]):
        print("TEST ENTERED EXIT WHILE LOOP")
        if (my_spot_exit_price() > (orderstatus["price"] + price_increment_spot)) or (my_spot_exit_price() < (orderstatus["price"] - price_increment_spot)) and \
                (orderstatus["status"] != "closed") and (orderstatus["filledSize"] != orderstatus["size"]):
            print(f"TIME SPOT EXIT 0 = {datetime.datetime.now()}")
            if orderstatus["status"] != "closed":
                try:
                    client.cancel_order(order_id=orderstatus["id"])
                    while orderstatus["status"] != "closed":
                        time.sleep(0.001)
                except: pass

            print(f"TIME SPOT EXIT 1 = {datetime.datetime.now()}")
        if (orderstatus["status"] == "closed") and (orderstatus["filledSize"] != orderstatus["size"]):
            client.place_order(market=f"{coin_spot}", side="sell", price=my_spot_exit_price(), type="limit", size=spot_size, post_only=True, reduce_only=True)
            while orderstatus["status"] != "new":
                time.sleep(0.001)
            print(f"TIME SPOT EXIT 2 = {datetime.datetime.now()}")

    # # PERP MARKET EXIT ORDER
    # perp_order = client.place_order(market=f"{coin_perp}", side="buy", price=0, type="market", size=spot_size, reduce_only=True)
    # time.sleep(2)
    # print(f"{coin}: PERP MARKET EXIT ORDER: {perp_order}")

    # PERP LIMIT EXIT
    client.place_order(market=f"{coin_perp}", side="buy", price=my_perp_exit_price(price_increment_perp), type="limit", size=spot_size, post_only=True, reduce_only=True)
    while orderstatus["status"] != "new":
        time.sleep(0.001)

    while (orderstatus["filledSize"] != orderstatus["size"]):
        if (orderstatus["price"] != ticker[1]) and (orderstatus["status"] != "closed") and (orderstatus["filledSize"] != orderstatus["size"]):
            print(f"TIME PERP EXIT 0 = {datetime.datetime.now()}")
            if orderstatus["status"] != "closed":
                try:
                    client.cancel_order(order_id=orderstatus["id"])
                    while orderstatus["status"] != "closed":
                        time.sleep(0.001)
                except: pass
            print(f"TIME PERP EXIT 1 = {datetime.datetime.now()}")
        if (orderstatus["status"] == "closed") and (orderstatus["filledSize"] != orderstatus["size"]):
            client.place_order(market=f"{coin_perp}", side="buy",price=my_perp_exit_price(price_increment_perp),type="limit",size=(orderstatus["size"] - orderstatus["filledSize"]),post_only=True,reduce_only=True)
            while orderstatus["status"] != "new":
                time.sleep(0.001)
            print(f"TIME PERP EXIT 2 = {datetime.datetime.now()}")