from arcgis.gis import GIS
from urllib.parse import urljoin
import json
import requests


def get_credentials(portalname='server'):
    '''Get the username and password for the Server sites in a Dict with keys: 'user' and 'pswd'
    use "uplan" for ArcGIS Online credentials
    '''

    with open('params.json', 'r') as jsonfile:

        jsontxt = jsonfile.read()
        params_json = json.loads(jsontxt)

    try:
        user = params_json['login'][portalname]['username']
        pswd = params_json['login'][portalname]['password']

        creds = {
            "user": user,
            "pswd": pswd
            }

        return creds

    except (KeyError) as e:
        print(rf"Error: Portal '{portalname}' not found. Use either 'uplan', or leave args empty for 'server' (default)")

        return None



def get_portal_url(portalname, site='home'):
    '''Get the URL of a portal main page or an admin site:
         params:
           portalname = 'central', 'projects', 'regions', 'roads', 'uplan'
           site = 'home' (default), 'admin', 'sharing'
    '''

    with open('params.json', 'r') as jsonfile:

        jsontxt = jsonfile.read()
        params_json = json.loads(jsontxt)

    try:
        portal = params_json['portals'][portalname][site]

        return portal

    except KeyError as keyerr:

        print(rf"Error: invalid pairing of portal and/or site names")

        if portalname not in params_json['portals']:
            print(f"  portal site '{portalname}' not found")

        elif site not in params_json['portals'][portalname]:
            print(f"  path '/{site}' not found in '{portalname}' portal path")

        return None



def get_server_url(portalname, server):
    '''Get the URL of the server admin site
         params:
           portalname:
           server:
    '''

    with open('params.json', 'r') as jsonfile:

        jsontxt = jsonfile.read()
        params_json = json.loads(jsontxt)

    try:
        server_admin_url = params_json['servers'][portalname][server]
        return server_admin_url

    except KeyError:
        print(rf"Error: Server '{server}' not found on Portal '{portalname}'")



def get_portal_token(portalname, exp_min=90):
    '''Returns a token that can be used by clients when working with the Portal Admin API.
    '''

    # get Portal credentials, stored outside version control
    # creds = get_credentials()
    creds = get_credentials()

    # build the URL to the 'Generate Token' endpoint
    try:
        token_url = urljoin(rf"{get_portal_url(portalname, 'sharing')}", "generateToken")
    except:
        print("Unable to create a valid path to /generateToken endpoint")
        return None

    # set the payload for the HTTP POST request
    # default expiration:  90 minutes

    payload = {
        "username": creds['user'],
        "password": creds['pswd'],
        "client": "requestip",
        "expiration": exp_min,
        "f": "json"
        }

    try:
        # send the POST requests using the Requests library
        r = requests.post(token_url, data=payload)
        # parse the token value out of the response JSON
        token = r.json()["token"]

        return token

    except:
        print(f"  unable to create a token for portal '{portalname}' ")
        return None



def get_server_token(portalname, server, exp_min=90):
    """Returns a token that can be used by clients when working with the Server Admin API """

    # get Server credentials, stored outside version control
    creds = get_credentials()

    # build the URL to the 'Generate Token' endpoint
    # https://developers.arcgis.com/rest/enterprise-administration/server/generatetoken/

    try:
        token_url = urljoin(rf"{get_server_url(portalname, server)}", "generateToken")
    except:
        print("Unable to create a valid path to /generateToken endpoint")
        return None

    # set the payload for the HTTP POST request
    # default expiration:  90 minutes

    payload = {
        "username": creds['user'],
        "password": creds['pswd'],
        "client": "requestip",
        "expiration": exp_min,
        "f": "json"
        }

    # send the POST requests using the Requests library
    r = requests.post(token_url, data=payload)

    # parse the token value out of the response JSON
    token = r.json()["token"]

    return token



def check_server_token(portalname, server, token):
    """checks if a server token is valid. if true, return it, else return a new one """

    # if token is an empty string, generate a new token and return it
    if not token:
        return get_server_token(portalname, server)

    # build URL for the ArcGIS Server REST endpoint
    # this endpoint requires a valid token, and returns a short JSON response, if successful

    server_url = get_server_url(portalname, server)

    # append /system to the server admin URL
    server_system_url = urljoin(server_url, "system")

    # send any payload to the /system endpoint
    payload = {
        'token': token,
        'f': 'json'
        }

    # should return:  {'resources': ['directories', 'configstore', 'licenses']}`
    # if successfully accessed endpoint with token

    try:
        r = requests.get(server_system_url, params=payload)

        resp = r.json()

        if 'resources' in resp:
            # API returned the expected response, token is valid, return it
            return token

        elif 'status' in resp:
            # API returned an error code: 498 or 499
            if resp['code'] in (498, 499):

                # generate a new token and return it
                return get_server_token(portalname, server)

    except Exeption as e:
        print(e)
        return Null



def get_gis(portalname):
    """Connect to an ArcGIS Server machine or UPlan portal in ArcGIS Online"
      options: 'central', 'projects', 'regions', 'roads', 'uplan"""

    with open('params.json', 'r') as jsonfile:

        if portalname == "uplan":
            creds = get_credentials("uplan")
        else:
            creds = get_credentials()

        url = get_portal_url(portalname)
        user = creds['user']
        pswd = creds['pswd']

    if creds and url:

        try:
            gis = GIS(url, user, pswd)

            if gis:
                print(f"Active Portal: {gis.url}")
            else:
                print("No active GIS connection")

            if gis.users.me:
                print(f"    username : {gis.users.me.username}")
                print(f"    user role: {gis.users.me.role}")
                return gis
            else:
                print("You are not signed in to the active portal")
                return None  # return None for testing if GIS connection exists
        except KeyError as e:
            print(e)
        except Exception as e:
            print(e)



def get_site_machines(portalname, server, token=''):
    """Returns a dict of the Machines registered with an ArcGIS Server site

    at: <root_url>/machines
    Normally, there is one machine per site.
    A High-Availabilty site may have more than one.
    """

    # build URL for the ArcGIS Server REST endpoint

    machines_subdir = "machines"
    server_url = get_server_url(portalname, server)
    machines_url = urljoin(server_url, machines_subdir)

    # set the payload for the HTTP GET request
    # use the provided token argument, if present, or generate a new one

    payload = {
        'token': check_server_token(portalname, server, token),
        'f': 'json'
        }
    r = requests.get(machines_url, params=payload)

    machines = r.json()

    return machines



def get_machine_status(portalname, server, machine, token=''):
    """Returns the Status of the specified Machine on the Server in Portal
    {'configuredState': 'STARTED', 'realTimeState': 'STARTED'}

    machine name example: 'srgwcongisserva.utah.utad.state.ut.us'
    """

    # build URL to REST endpoint
    machine_status_subdir = f"machines/{machine}/status"

    server_url = get_server_url(portalname, server)
    machine_status_url = urljoin(server_url, machine_status_subdir)

    payload = {
        'token': check_server_token(portalname, server, token),
        'f': 'json'
        }

    r = requests.get(machine_status_url, params=payload)

    machine_status = r.json()

    return machine_status
