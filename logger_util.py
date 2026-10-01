
import logging
from pathlib import Path
from datetime import datetime as dt


# set the global logging level
# this is the minimum logging level that will be retained in all log files and output streams
# Formatters can be set individually below:
#  ex: DEBUG for stdout and INFO for log file

global_log_level = logging.INFO
# global_log_level = logging.DEBUG


# create the log file path and object
def get_logfile(log_basename):
    '''Create the log file as a pathlib.WindowsPath object'''

    # subfolder storing log files at:  .\logs\
    logfile_folder = Path(r'logs')

    # filename of log file with date and time appended YYYY-MM-DD_HHMM
    logfile_name = Path(f"{log_basename}_{dt.strftime(dt.today(), r'%Y-%m-%d_%H%M')}")

    # add the .log suffix to the WindowsPath
    logfile = Path(logfile_folder, logfile_name).with_suffix('.log')

    # create the log file if it does not already exist
    if not logfile.is_file():
        try:
            logfile.touch()
        except FileNotFoundError:
            print("Unable to create new log file. Path may be invalid.")

    # return the pathlib.WindowsPath
    return logfile


# Root Logger

# use the name 'root' when creating the root Logger object
# all imported modules will forward messages to the root Logger
#
# this will also include logs from all standard library modules
# which might catch more than you want, especially on DEBUG level
# use a different name to limit log messages to modules in this project only
#
# when not using "root" as the Logging object name:
# all imported modules must have Logger objects with the base module Logger name
# with a dot to indicate a lower-level modules in the hierarchical logging
# ex: logger = logging.getLogger("base_module.submodule_name")


def rootlogger(log_basename):

    # create Logger object
    logger = logging.getLogger("root")

    # set the log level on the Logger object
    # nothing below this level will be retained in the Handlers
    logger.setLevel(global_log_level)

    # get the path to the log file for this portal
    logfile = get_logfile(log_basename)

    # Set the format of the Log messages
    # the string written to the Formatter
    # ex:  Tue 2025-07-08 10:24:07 - INFO MODULE info-level message text here

    # Formatter config sets up defaults in the Handlers defied below
    fmt_str = "{asctime} - {levelname:<8} {name:<12} {message}"
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

    return logger
