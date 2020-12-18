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

  for (var i = 0; i < workerAmount; i++) {
    Locker newLocker = await isolateLocker.requestNewLocker();

    print("C Creating Worker " + i.toString());

    Isolate.spawn(workerIsolateFunc, WorkerConfig(newLocker, i));
  }

  isolateLocker.kill();
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
