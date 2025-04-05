package io.nekohasekai.sagernet.aidl;

import io.nekohasekai.sagernet.aidl.ISagerNetServiceCallback;
import io.nekohasekai.sagernet.aidl.Group;
import io.nekohasekai.sagernet.aidl.GroupItem;

interface ISagerNetService {
  int getState();
  String getProfileName();

  void registerCallback(in ISagerNetServiceCallback cb, int id);
  oneway void unregisterCallback(in ISagerNetServiceCallback cb);

  int urlTest(String tag);

  oneway void enableDashboardStatus(boolean enable);
  oneway void closeConnection(String id);
  oneway void resetNetwork();
  List<String> getClashModes();
  String getClashMode();
  oneway void setClashMode(String mode);
  oneway void groupSelecte(String group, String tag);
  List<Group> getGroups();
  List<GroupItem> queryGroup(String group);
}
