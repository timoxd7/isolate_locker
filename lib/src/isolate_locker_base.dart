import 'dart:async';
import 'dart:isolate';
import 'package:mutex/mutex.dart';

class _LockerQueueEntry {
  Future<void> queueEntry;
  int number;
}

class Locker {
  SendPort _lockerIsolatePort;
  bool _dead = false;

  /// Besides the lock between the independent isolates, there also needs to be
  /// a Lock between async code in the same Isolate. To lock them against each
  /// other, using a Mutex from the mutex package is the best way.
  Mutex _m = Mutex();

  /// Awaiting this Future, you can Lock the specific IsolateLocker to
  /// exclusively use it. Use just with "await" to wait for the lock to be
  /// accepted
  Future<void> request() async {
    if (_dead) return;

    await _m.acquire();
    await _lockWithState(true);
  }

  /// Release a once given lock. request() has to be called first!
  void release() async {
    if (_dead) return;

    await _lockWithState(false);
    _m.release();
  }

  /// To prevent misusage by forgetting release, you can just encapsulate a
  /// Function in the protect function. The function then gets only called,
  /// once a Lock has been accepted. Use only this whenever possible!
  Future<void> protect(Function criticalSection) async {
    await request();

    try {
      await criticalSection();
    } finally {
      release();
    }
  }

  /// Only if the Isolate should be terminated! This will render this Locker
  /// permanently useless. Only use if all sync and async code which could
  /// use this Locker is fully completed!
  void kill() async {
    await _m.acquire();

    _SendPortRequest message = _SendPortRequest();
    message.action = false;
    _lockerIsolatePort.send(message);
    _dead = true;

    _m.release();
  }

  bool isDead() {
    return _dead;
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
    _lockerIsolatePort.send(lockRequest);
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
  bool action =
      true; // true == get new SendPort, false == kill this ReceivePort
}

class _KillRequest {
  bool action = true; // true == kill
}

void _lockerIsolateFunc(SendPort mainSendPort) {
  ReceivePort receivePort = ReceivePort();
  bool locked = false;
  var pendingLocks = List<_LockRequest>();

  bool killRequested = false;
  int openPortCount = 0;

  void tryKillMe() {
    if (openPortCount == 0 && killRequested) {
      _KillRequest killRequest = _KillRequest();
      killRequest.action = true;
      mainSendPort.send(killRequest);
      receivePort.close();
    }
  }

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
    if (killRequested) return;

    if (message is _SendPortRequest) {
      _SendPortRequest request = message;

      if (request.action == true) {
        var newReceivePort = ReceivePort();

        newReceivePort.listen((message) {
          if (message is _LockRequest) {
            _LockRequest lockRequest = message;
            proccessLockRequests(lockRequest);

            while (!locked && pendingLocks.isNotEmpty) {
              proccessLockRequests(pendingLocks.first);
              pendingLocks.removeAt(0);
            }
          } else if (message is _SendPortRequest) {
            _SendPortRequest request = message;

            if (request.action == false) {
              newReceivePort.close();
              openPortCount--;
            }

            tryKillMe();
          }
        });

        mainSendPort.send(newReceivePort.sendPort);
        openPortCount++;
      }
    } else if (message is _KillRequest) {
      _KillRequest killRequest = message;

      if (killRequest.action == true) {
        killRequested = true;

        tryKillMe();
      }
    }
  });

  mainSendPort.send(receivePort.sendPort);
}

class IsolateLocker {
  SendPort _lockerSendPort;
  final _lockReceivePort = ReceivePort();
  final _lockerSenderPortCompleter = Completer();
  var _newLockerCompleter = Completer();
  bool _dead = false;
  Mutex _m = Mutex();

  /// Create a new IsolateLocker to lock something globally
  IsolateLocker() {
    void _isolateListener() async {
      await for (dynamic message in _lockReceivePort) {
        if (message is SendPort) {
          if (_lockerSendPort == null) {
            // Use first sendPort for the communication with main
            _lockerSendPort = message;
            print("Locker set up");
            _lockerSenderPortCompleter.complete();
          } else {
            Locker newLocker = Locker();
            newLocker._lockerIsolatePort = message;
            _newLockerCompleter.complete(newLocker);
          }
        } else if (message is _KillRequest) {
          _KillRequest killRequest = message;
          if (killRequest.action == true) _lockReceivePort.close();
        }
      }
    }

    _isolateListener();
    Isolate.spawn(_lockerIsolateFunc, _lockReceivePort.sendPort);
  }

  /// Get a new Locker to pass to a new Isolate which then can Lock the
  /// IsolateLocker once it needs a specific resource.
  Future<Locker> requestNewLocker() async {
    if (_dead) return null;

    await _m.acquire();

    await _lockerSenderPortCompleter.future;

    _newLockerCompleter = Completer();
    var _sendPortRequest = _SendPortRequest();
    _lockerSendPort.send(_sendPortRequest);
    Locker newLocker = await _newLockerCompleter.future;

    _m.release();

    return newLocker;
  }

  /// Kill the IsolateLocker. This only gives a Signal to the Isolate Locker.
  /// The Kill will only be executed if all Locks also have been killed.
  /// This will Render this IsolateLocker useless!
  void kill() {
    _KillRequest _killRequest = _KillRequest();
    _killRequest.action = true;
    _lockerSendPort.send(_killRequest);
    _dead = true;
  }
}
