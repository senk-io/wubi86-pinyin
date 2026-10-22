// 只读：向系统输入法服务（TIS）查询一个输入源的状态，输出 enabled、disabled 或 absent。
// 不看 com.apple.HIToolbox 偏好文件：输入法被强制结束过之后，那个文件可能和系统的实际状态不一致。
// 用法：osascript -l JavaScript scripts/input-source-state.js <输入源 ID>
ObjC.import('Carbon')

function run(argv) {
  // 键就是 kTISPropertyInputSourceID 的字符串值
  const filter = $.NSDictionary.dictionaryWithObjectForKey($(argv[0]), $('TISPropertyInputSourceID'))
  // 第二个参数为 false 时只列出已启用的输入源，为 true 时列出所有已安装的。
  // 不读 IsEnabled 属性：它的布尔值经 JXA 桥接后读不准（CI 上当前键盘也读成 false）
  const count = all => ObjC.castRefToObject($.TISCreateInputSourceList(filter, all)).count
  if (count(false) > 0) return 'enabled'
  return count(true) > 0 ? 'disabled' : 'absent'
}
