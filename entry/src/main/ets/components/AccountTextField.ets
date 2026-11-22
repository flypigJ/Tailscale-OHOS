/** Keep input/focus updates inside a stable native TextInput component. */
@Component
export struct AccountTextField {
  @Link value: string;
  @Prop fieldId: string = '';
  @Prop placeholder: ResourceStr = '';
  @Prop inputEnabled: boolean = true;
  @Prop password: boolean = false;
  @State private focused: boolean = false;
  onEdited: () => void = () => {};

  build() {
    TextInput({ text: $$this.value, placeholder: this.placeholder })
      .id(this.fieldId)
      .type(this.password ? InputType.Password : InputType.Normal)
      .enableAutoFill(false)
      .copyOption(this.password ? CopyOptions.None : CopyOptions.LocalDevice)
      .maxLength(4096)
      .width('100%')
      .height(48)
      .padding({ left: 12, right: 12 })
      .fontSize(13)
      .fontColor($r('sys.color.font_primary'))
      .placeholderColor($r('sys.color.font_secondary'))
      .backgroundColor($r('sys.color.comp_background_tertiary'))
      .border({ width: 1, color: this.focused ? $r('app.color.emphasize') : $r('sys.color.comp_divider') })
      .borderRadius(12)
      .enabled(this.inputEnabled)
      .onFocus(() => { this.focused = true; })
      .onBlur(() => { this.focused = false; })
      .onChange(() => this.onEdited())
  }
}
