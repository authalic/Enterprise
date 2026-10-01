
from datetime import datetime as dt
from zoneinfo import ZoneInfo

#for testing
import time



class timer:
    '''mark the start and stop times, for updating the 'SD Info' table'''

    def __init__(self):
        '''set the start time at instantiation'''

        self.timer_start = dt.now(tz=ZoneInfo("America/Denver"))
        self.timer_stop = None


    def _stop(self):
        '''get the stop time as a datetime.datetime'''

        # Note: Don't call this in code. Use the next two functions

        self.timer_stop = dt.now(tz=ZoneInfo("America/Denver"))
        return(self.timer_stop)


    def end_timestamp(self):
        '''return the timestamp as a formatted string'''

        if self.timer_stop:
            return self.timer_stop.strftime('%Y-%m-%d %I:%M:%S %p')
        else:
            self._stop()
            return self.timer_stop.strftime('%Y-%m-%d %I:%M:%S %p')


    def elapsed(self):
        '''return the elapsed time as datetime.timedelta'''

        if self.timer_stop:
            self.timer_duration = self.timer_stop - self.timer_start
            return str(self.timer_duration)
        else:
            self._stop()
            self.elapsed()


if __name__ == '__main__':
    print('\n')

    timetest = timer()
    print(timetest.timer_start)

    time.sleep(6)
    # print(timetest.stop())
    print(timetest.end_timestamp())
    print(timetest.elapsed())
