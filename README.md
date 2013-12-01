CSMNSService
============

A bluetooth library for getting notifications from your phone when you get texts

Example:
-------

```Objective-C
CSMNSService *service = [CSMNSService new];
[service startListening:[IOBluetoothDevice deviceWithAddressString:@"00-00-00-00-00-00"]];
```
