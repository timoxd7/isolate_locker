import 'dart:isolate';
import 'package:mutex/mutex.dart';

class _LockerQueueEntry {
  Future<void> queueEntry;
  int number;
}

class Locker {
  SendPort lockerIsolatePort;

  /// Besides the lock between the independent isolates, there also needs to be
  /// a Lock between async code in the same Isolate. To lock them against each
  /// other, using a Mutex from the mutex package is the best way.
  Mutex m = Mutex();

  Future<void> request() async {
    await m.acquire();
    await _lockWithState(true);
  }

  void release() async {
    await _lockWithState(false);
    m.release();
  }

  Future<void> protect(Function criticalSection) async {
    await request();

    try {
      await criticalSection();
    } finally {
      release();
    }
  }

  Future<void> _lockWithState(bool newLockState) async {
    var lockRequest = _LockRequest();
    var newReceivePort = ReceivePort();
    lockRequest.action = newLockState;
    lockRequest.responsePort = newReceivePort.sendPort;

    Future<_LockResponse> lockListener() async {
      _LockResponse lockResponse;

      await for (dynamic message in newReceivePort) {
        if (message is _LockResponse) {
          lockResponse = message;
          newReceivePort.close();
          break;
        }
      }

      return lockResponse;
    }

    var lockResponseFuture = lockListener();
    lockerIsolatePort.send(lockRequest);
    var realLockResponse = await lockResponseFuture;
    // Maybe use the response sometime
  }
}

class _LockRequest {
  SendPort responsePort;
  bool action;
}

class _LockResponse {
  bool success;
}

class _SendPortRequest {
  _SendPortRequest(int amount) {
    this.amount = amount;
  }

  int amount;
}

void _lockerIsolateFunc(SendPort mainSendPort) {
  ReceivePort receivePort = ReceivePort();
  bool locked = false;
  var pendingLocks = List<_LockRequest>();

  bool proccessLockRequests(_LockRequest request) {
    var response = _LockResponse();

    if (request.action) {
      if (locked) {
        // Already locked, needs to be locked later
        pendingLocks.add(request);
      } else {
        // Complete a lock
        response.success = true;
        locked = true;
        request.responsePort.send(response);
      }
    } else {
      if (locked) {
        // Unlock locked Lock
        response.success = true;
        locked = false;
        request.responsePort.send(response);
      } else {
        // Cant unlock unlocked Lock!
        response.success = false;
        request.responsePort.send(response);
      }
    }
  }

  receivePort.listen((dynamic message) {
    if (message is _SendPortRequest) {
      _SendPortRequest request = message;

      for (int i = 0; i < request.amount; i++) {
        var newReceivePort = ReceivePort();

        newReceivePort.listen((message) {
          if (message is _LockRequest) {
            _LockRequest lockRequest = message;
            proccessLockRequests(lockRequest);

            while (!locked && pendingLocks.isNotEmpty) {
              proccessLockRequests(pendingLocks.first);
              pendingLocks.removeAt(0);
            }
          }
        });

        mainSendPort.send(newReceivePort.sendPort);
      }
    }
  });

  mainSendPort.send(receivePort.sendPort);
}

class IsolateLocker {
  SendPort _lockerSendPort;

  /**
   * newLockerReady = Callback if a new Locker for a worker Isolate is ready
   * newIsolateReady = The Isolated Locker is ready and new Locker can now be generates
   */
  IsolateLocker(Function(Locker) newLockerReady, Function() isolatorReady) {
    var lockReceivePort = ReceivePort();

    void _isolateListener() async {
      await for (dynamic message in lockReceivePort) {
        if (message is SendPort) {
          if (_lockerSendPort == null) {
            // Use first sendPort for the communication with main
            _lockerSendPort = message;
            print("Locker set up");
            isolatorReady();
          } else {
            Locker newLocker = Locker();
            newLocker.lockerIsolatePort = message;
            newLockerReady(newLocker);
          }
        }
      }
    }

    _isolateListener();
    Isolate.spawn(_lockerIsolateFunc, lockReceivePort.sendPort);
  }

  bool requestNewLocker({int amount = 1}) {
    if (_lockerSendPort == null) return false;

    _lockerSendPort.send(_SendPortRequest(amount));
    return true;
  }
}
