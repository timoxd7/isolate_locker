import 'package:isolate_locker/isolate_locker.dart';
import 'dart:isolate';

IsolateLocker isolateLocker;
const int workerAmount = 100;
const int waitTime = 0;

class WorkerConfig {
  WorkerConfig(Locker locker, int id) {
    this.locker = locker;
    this.id = id;
  }

  Locker locker;
  int id;
}

void main() async {
  isolateLocker = IsolateLocker();
  int workerCount = 0;
  bool done = false;

  void checkLife() {
    if (workerCount == 0 && done) isolateLocker.kill();
  }

  void workerRemovedListener(ReceivePort receiverPort) async {
    await for (dynamic message in receiverPort) {
      // -> ended
      workerCount--;
      checkLife();
      receiverPort.close();
    }
  }

  for (var i = 0; i < workerAmount; i++) {
    ReceivePort currentReceivePort = ReceivePort();
    Locker newLocker = await isolateLocker.requestNewLocker();

    print("C Creating Worker " + i.toString());

    workerRemovedListener(currentReceivePort);

    Future<Isolate> newIsolate = Isolate.spawn(
        workerIsolateFunc, WorkerConfig(newLocker, i),
        onExit: currentReceivePort.sendPort);

    workerCount++;
  }

  done = true;
  checkLife();
}

void workerIsolateFunc(WorkerConfig conf) async {
  await workerRoutine(1, conf);
  await workerRoutine(2, conf);
  conf.locker.kill();
}

void workerRoutine(int count, WorkerConfig conf) async {
  print(count.toString() + " W " + conf.id.toString() + " requesting now");
  await conf.locker.request();
  print(count.toString() +
      " W " +
      conf.id.toString() +
      " successfully requested");

  if (waitTime > 0) {
    await Future.delayed(
        Duration(milliseconds: waitTime)); // Simulate some heeeavy task
  }

  print(count.toString() + " W " + conf.id.toString() + " releasing now");
  await conf.locker.release();
  print(count.toString() + " W " + conf.id.toString() + " released");
}
