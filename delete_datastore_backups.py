# %% [markdown]
# # Bug Workaround: delete oldest data store backups
# ## ArcGIS Data Store
#   - relational data store saves backups in folders inside the folder at: `D:\arcgisdatastore\backup\relational\dbbackup`
#   - backups are scheduled using:  `updatebackupschedule.bat`
#   - retention day setting is at:  `updatebackupretaindays.bat`
#
# ## Bug
# - **Relational Data Store 12.1 does not respect configured backup retention period**
#   - BUG-000187391
#   - https://my.esri.com/#/support/bugs/bugs?bugNumber=BUG-000187391
#
# ### Workaround
# - Manually delete the ArcGIS Data Store 12.1 Relational Store backups from the backup location.

# %% [markdown]
# ## Future improvements
#
# - summarize the content for each folder in the archive directories
#   - bytes contained
#   - files contained
#   - this could add some significant runtime on the Object store
# - add elapsed time for folder deletion
#   - yeah, this could be done by subtracting the timestamps, but still...

# %%
import os.path
import logging
from pathlib import Path
from shutil import rmtree
from datetime import datetime as dt
from datetime import timedelta

# %%
# get the timestamp of the start time
# this determines the timedeltas used below

start_ts = dt.now()

# %%
# path containing the backup directories
# this is usually the path to the Relational Data Store backup folder
# but can also include the path to an Object Store or another type

backup_folders = [
    r'D:\arcgisdatastore\backup\relational\dbbackup',
    r'D:\arcgisdatastore\backup\object'
    ]

# delete any directory with last-edit age older than 'dt.timedelta(days=retention_days)'
retention_days = 4

# for naming the output log file  (comment all but one)
log_portalname = [
    "central",
    # "projects",
    # "regions",
    # "roads"
    ]

# test mode active. True = will not delete anything. shows what would be deleted
testing = True

# %%
def timestamp_string(timestamp):
    '''returns a timestamp as a formatted string. Ex "2026-10-06 13:29:32" for logs'''

    time_str = timestamp.strftime('%Y-%m-%d %H:%M:%S' )
    # time_str = f"{time_str}.{now_dt.strftime('%f'):<.1}"  # adds decimal seconds

    return time_str

# %%
def duration_string(delta):
    '''formats a datetime.timedelta as a formatted string. Ex: "2 days, 04:03:04 (H:M:S)" for logs'''

    d_days = delta.days
    d_sec = delta.seconds
    d_hours = d_sec // 3600
    d_min = ((d_sec - (d_hours * 3600)) // 60)
    d_sec = d_sec - (d_hours * 3600) - (d_min * 60)

    # ex: 03d 04h 34m 07s
    duration_str = f"{d_days:>02}d {d_hours:>02}h {d_min:>02}m {d_sec:>02}s"
    return duration_str

# %%
# start logging
global_log_level = logging.INFO

# logger = logging.getLogger("root")
logger = logging.getLogger("datastore")

logger.setLevel(global_log_level)

# Log File
# subfolder storing log files at:  .\logs\
logfile_folder = Path(r'logs')
log_basename = "datastore"

# filename of log file, from the list above
logfile_name = Path(f"{log_basename}_{log_portalname[0]}")

# add the .log suffix to the WindowsPath
logfile = Path(logfile_folder, logfile_name).with_suffix('.log')

# create the log file if it does not already exist
if not logfile.is_file():
    try:
        logfile.touch()
    except FileNotFoundError:
        logger.error("Unable to create new log file. Path may be invalid.")


# Formatters
# Set the format of the Log messages string written to the Formatter
# ex:  Tue 2025-07-08 10:24:07 - INFO MODULE info-level message text here

# Formatter config sets up defaults in the Handlers defied below
fmt_str = "{asctime} - {levelname:<8} {message}"
fmt_date = "%Y-%m-%d %H:%M:%S"
fmt_style = "{"

# create Formatter object
log_formatter = logging.Formatter(fmt=fmt_str, datefmt=fmt_date, style=fmt_style)


# Handlers
# configure the Logger with a File Handler and output Stream Handler

# File Handler
# (sends log message to log file)
log_handler_file = logging.FileHandler(logfile, mode='a', encoding='UTF-8')
log_handler_file.setLevel(logging.DEBUG)
log_handler_file.setFormatter(log_formatter)

# Stream Handler
# (sends log messages to sys.stderr)
log_handler_stream = logging.StreamHandler()
log_handler_stream.setLevel(logging.DEBUG)    # change this to INFO if you only want to see that in the Cell outputs
log_handler_stream.setFormatter(log_formatter)

# add the Handlers to the Logger object
logger.addHandler(log_handler_file)
logger.addHandler(log_handler_stream)

# usage:  logger.info("message")
logger.info(f"***** Start: {timestamp_string(start_ts)} *****")
logger.info(f"Retention Days: {retention_days}")

# %%
def get_directory_last_edit(dir_path):
    '''Returns the most recent modification datetime of a directory as datetime'''

    # get the root directory metadata modification time
    try:
        # get the Unix timestamp <class 'float'>, ex: 1788470738.355496
        dir_time = os.path.getmtime(dir_path)

    except (OSError, FileNotFoundError):
        logger.error(f"Error getting timestamp of directory: {dir_path}")

    # convert timestamp (float) to datetime.datetime
    return dt.fromtimestamp(dir_time)

# %%
def get_subdirectories(dir_path):
    '''returns a list of subdirectories sorted by last edit timestamp'''

    # each folder item is stored as a list within the list
    #   item[0] = full path to folder
    #   item[1] = timestamp of most recently updated item (folder or file) within that path

    do_not_delete = ['.data_store']  # never delete this folder

    path_list = []

    for item in os.listdir(dir_path):

        dir_full = os.path.join(dir_path, item)
        last_mtime = get_directory_last_edit(dir_full)

        if os.path.isdir(dir_full):
            if item not in do_not_delete:


                # append to path_list, a list containing:
                #  full path to the dir
                #  timestamp of its most recent edit
                #  timedelta from the last edit to the start time of the script

                dir_age = start_ts - last_mtime  # age of last edit as a timedelta
                path_list.append([dir_full, last_mtime, dir_age])

                # display only the folder name, not full path, log the timestamp of last update and the time delta

    # sort the list by timestamp (ascending)
    path_list.sort(key=lambda x: x[1])

    # log the paths, with filename, last update timestamp, and age of dir

    for path in path_list:
        path_str = path[0]
        pt_path = Path(path_str)
        filename = pt_path.name

        logger.info(f"  {filename:<32} updated: {timestamp_string(path[1])}   age: {duration_string(path[2])}")

    # log the paths in sorted order
    # it can take a very long time to get the files individually.
    # Skip this until the number is manageable
    # Meanwhile, log them in the loop above as they are examined

    return path_list

# %%
def delete_oldest_dirs(path_list, retention_days, testing):
    '''deletes any path in path_list with last-edit date older than the retention day limit'''

    logger.info(f"--deleting subfolders older than retention limit")
    if testing:
        logger.info("  TESTING mode enabled. Deletable directories indicated below, with *TESTING*")

    # number of retention days as timedelta
    retention_days_delta = timedelta(days=retention_days)

    for dir_list in path_list:

        path_str = dir_list[0]            # full path to dir
        pt_path = Path(path_str)
        filename = pt_path.name

        dir_age = dir_list[2]  # age of last edit as a timedelta

        if dir_age > retention_days_delta:
            # folder is older than the rentention day limit

            if not testing:
                logger.info(f"  {'DELETING':<10}: {filename:<32}    age: {duration_string(dir_age)}")
                rmtree(dir_path)
            else:
                # do not delete anything if testing is True
                logger.info(f"  {'*TESTING*':<10}: {filename:<32}    age: {duration_string(dir_age)}")
        else:
            logger.info(f"  {'SKIPPING':<10}: {filename:<32}    age: {duration_string(dir_age)}")

# %%
if __name__ == '__main__':

    for backup_dir in backup_folders:
        # check if the directory exists (this allows the same list to be used on all portals)

        logger.info(f"Backup Directory:  {backup_dir}")
        p = Path(backup_dir)

        if p.is_dir():
            path_list = get_subdirectories(backup_dir)
            delete_oldest_dirs(path_list, retention_days, testing)
        else:
            logger.info(f"  {backup_dir} is not a valid directory")


    # log the stop time and duration
    stop_ts = dt.now()
    logger.info(f"done: {timestamp_string(stop_ts)}  elapsed: {duration_string(stop_ts - start_ts)}")

    logging.shutdown()
