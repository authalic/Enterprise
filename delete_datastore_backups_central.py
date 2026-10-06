
### delete datastore backups: Central Portal

# Central Portal contains two Data Store types
#  - Relational Data Store
#     - retention policy is part of the configuration, but is currently affected by bug (see below)
#     - each backup is ~
#  - Object Store
#     - does not have any setting to retain backups for a specified number of days
#     - each backup is ~4 GB

# Data Store Bug  **Relational Data Store 12.1 does not respect configured backup retention period**
# Esri BUG-000187391
# https://my.esri.com/#/support/bugs/bugs?bugNumber=BUG-000187391


# Summary:
# this script will look at the backup folders on the Central Portal Data Store machine
#   D:\arcgisdatastore\backup\object
#   D:\arcgisdatastore\backup\relational
# each backup is stored in a folder
# if the newest file a backup folder, or the folder itself, is older than the retention limit, delete it

# written by:  Justin Johnson justinpjohnson@utah.gov
# October 2026
# reconfigured to include Object Store

# DO NOT DISABLE THIS SCRIPT
#  or, if necessary, remove the Relational Data Store directory after the Bug has been resolved


import os.path
from pathlib import Path
from shutil import rmtree
from datetime import datetime as dt
from datetime import timedelta

# path containing the backup directories
backup_folders = [
    r'D:\arcgisdatastore\backup\relational\dbbackup',
    r'D:\arcgisdatastore\backup\object'
    ]

# delete any directory with last-edit age older than 'dt.timedelta(days=retention_days)'
retention_days = 4

# for naming the output log file
log_portalname = "central"  # "projects", "regions", "roads", "central"

# test mode active
testing = True


### Logging for scheduled tasks

# start logging
import logging

global_log_level = logging.INFO

logger = logging.getLogger("root")
logger.setLevel(global_log_level)

# Log File
# subfolder storing log files at:  .\logs\
logfile_folder = Path(r'logs')
log_basename = "datastore"

# filename of log file
logfile_name = Path(f"{log_basename}_{log_portalname}")

# add the .log suffix to the WindowsPath
logfile = Path(logfile_folder, logfile_name).with_suffix('.log')

# create the log file if it does not already exist
if not logfile.is_file():
    try:
        logfile.touch()
    except FileNotFoundError:
        logger.error("Unable to create new log file. Path may be invalid.")


## Formatters
# Set the format of the Log messages string written to the Formatter
# ex:  Tue 2025-07-08 10:24:07 - INFO MODULE info-level message text here

# Formatter config sets up defaults in the Handlers defied below
fmt_str = "{asctime} - {levelname:<8} {name:<12} {message}"
fmt_date = "%Y-%m-%d %H:%M:%S"
fmt_style = "{"

# create Formatter object
log_formatter = logging.Formatter(fmt=fmt_str, datefmt=fmt_date, style=fmt_style)


## Handlers
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
logger.info("***** Start *****")
logger.info(f"Backup Directory:  {backup_dir}")
logger.info(f"Retention Days: {retention_days}")

# End of logging setup


### functions

def get_directory_last_edit(dir_path):
    '''Returns the most recent modification datetime of a directory or any file within it'''

    # Start with the root directory's own metadata modification time
    latest_time = os.path.getmtime(dir_path)

    # Recursively check all files and subdirectories
    for root, dirs, files in os.walk(dir_path):

        for item in dirs + files:
            item_path = os.path.join(root, item)

            try:
                mtime = os.path.getmtime(item_path)
                if mtime > latest_time:
                    latest_time = mtime

            except (OSError, FileNotFoundError):
                # Handle permissions or broken symlinks gracefully
                logger.error(f"Error getting timestamp of directory: {dir_path}")
                continue

    # return the timestamp of the folder or the most recently edited item within it
    return dt.fromtimestamp(latest_time)


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

                # append the full path to the dir and the timestamp of its most recent edit
                path_list.append([dir_full, last_mtime])

    # sort the list by timestamp (ascending)
    path_list.sort(key=lambda x: x[1])

    logger.info("Subfolders found:")

    for path in path_list:
        logger.info(f"  {path[0]:<48} last update: {str(path[1])}")

    return path_list


def delete_oldest_dirs(path_list, retention_days, testing):
    '''deletes any path in path_list with last-edit date older than the retention day limit'''

    logger.info(f"deleting subfolders older than retention limit")
    if testing:
        logger.info("  TESTING mode enabled")

    dt_now = dt.now()

    # number of retention days as timedelta
    retention_days_delta = timedelta(days=retention_days)

    for dir_list in path_list:

        dir_path = dir_list[0]         # full path to dir
        dt_age = dt_now - dir_list[1]  # age of last edit as a timedelta

        if dt_age > retention_days_delta:
            # folder is older than the rentention day limit

            if not testing:
                logger.info(f"  deleting: {dir_path:<40} age: {dt_age}")
                rmtree(dir_path)
            else:
                # do not delete anything if testing is True
                logger.info(f"  TESTING MODE: would have deleted {dir_path:<40} age: {dt_age}")
        else:
            logger.info(f"  NOT deleting: {dir_path:<40} age: {dt_age}")


if __name__ == '__main__':

    for backup_dir in backup_folders:
        path_list = get_subdirectories(backup_dir)
        delete_oldest_dirs(path_list, retention_days, testing)

    logging.shutdown()
