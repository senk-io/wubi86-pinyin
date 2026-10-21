// 只读：向系统输入法服务（TIS）查询一个输入源的状态，输出 enabled、disabled 或 absent。
// 不看 com.apple.HIToolbox 偏好文件：鼠须管被强制结束过之后，那个文件可能和系统的实际状态不一致。
// 用法：osascript -l JavaScript scripts/input-source-state.js <输入源 ID>
ObjC.import('Carbon')

function run(argv) {
  // 两个键就是 kTISPropertyInputSourceID、kTISPropertyInputSourceIsEnabled 的字符串值
  const filter = $.NSDictionary.dictionaryWithObjectForKey($(argv[0]), $('TISPropertyInputSourceID'))
  const list = ObjC.castRefToObject($.TISCreateInputSourceList(filter, true))
  if (list.count === 0) return 'absent'
  const enabled = ObjC.castRefToObject($.TISGetInputSourceProperty(list.objectAtIndex(0), $('TISPropertyInputSourceIsEnabled')))
  return enabled.boolValue ? 'enabled' : 'disabled'
}
