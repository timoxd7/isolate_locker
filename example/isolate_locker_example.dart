import 'package:isolate_locker/isolate_locker.dart';
import 'dart:isolate';

IsolateLocker isolateLocker;
const int workerAmount = 1;
const int waitTime = 3000;
int workerCount = 0;

class WorkerConfig {
  WorkerConfig(Locker locker, int id) {
    this.locker = locker;
    this.id = id;
  }

  Locker locker;
  int id;
}

void main() async {
  isolateLocker = IsolateLocker(newLockerReady, isolateReady);
}

void isolateReady() {
  isolateLocker.requestNewLocker(amount: workerAmount);
}

void newLockerReady(Locker newLocker) {
  print("C Creating Worker " + workerCount.toString());
  Isolate.spawn(workerIsolateFunc, WorkerConfig(newLocker, workerCount++));
}

void workerIsolateFunc(WorkerConfig conf) async {
  workerRoutine(1, conf);
  workerRoutine(2, conf);
}

void workerRoutine(int count, WorkerConfig conf) async {
  print(count.toString() + " W " + conf.id.toString() + " requesting now");
  await conf.locker.request();
  print(count.toString() +
      " W " +
      conf.id.toString() +
      " successfully requested");

  await Future.delayed(
      Duration(milliseconds: waitTime)); // Simulate some heeeavy task

  print(count.toString() + " W " + conf.id.toString() + " releasing now");
  await conf.locker.release();
  print(count.toString() + " W " + conf.id.toString() + " released");
}
