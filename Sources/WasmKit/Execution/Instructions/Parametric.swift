/// > Note:
/// <https://webassembly.github.io/spec/core/exec/instructions.html#parametric-instructions>
extension ExecutionState {
    mutating func select(context: inout StackContext, sp: Sp, selectOperand: Instruction.SelectOperand) throws {
        let flag = sp[selectOperand.condition].i32
        let selected = flag != 0 ? selectOperand.onTrue : selectOperand.onFalse
        let value = sp[selected]
        sp[selectOperand.result] = value
    }
}
