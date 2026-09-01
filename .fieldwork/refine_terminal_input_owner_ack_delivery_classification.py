from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old[:180]!r}")
    p.write_text(text.replace(old, new, 1))


runtime = "cmux-tui/crates/cmux-tui-core/src/terminal_host_runtime.rs"
replace_once(
    runtime,
    '''    pub(crate) struct InputAckReceipt {\n''',
    '''    #[derive(Debug)]\n    pub(crate) enum InputAckBeginFailure {\n        Known(std::io::Error),\n        Ambiguous(std::io::Error),\n    }\n\n    pub(crate) struct InputAckReceipt {\n''',
)
replace_once(
    runtime,
    '''        pub(crate) fn begin_input_confirmed(\n            &self,\n            payload: &[u8],\n        ) -> std::io::Result<InputAckReceipt> {\n''',
    '''        pub(crate) fn begin_input_confirmed(\n            &self,\n            payload: &[u8],\n        ) -> Result<InputAckReceipt, InputAckBeginFailure> {\n''',
)
replace_once(
    runtime,
    '''                return Err(std::io::Error::new(\n                    std::io::ErrorKind::Unsupported,\n                    "terminal host cannot acknowledge receipted input",\n                ));\n''',
    '''                return Err(InputAckBeginFailure::Known(std::io::Error::new(\n                    std::io::ErrorKind::Unsupported,\n                    "terminal host cannot acknowledge receipted input",\n                )));\n''',
)
replace_once(
    runtime,
    '''                return Err(std::io::Error::new(\n                    std::io::ErrorKind::WouldBlock,\n                    "terminal host receipted-input window is full",\n                ));\n''',
    '''                return Err(InputAckBeginFailure::Known(std::io::Error::new(\n                    std::io::ErrorKind::WouldBlock,\n                    "terminal host receipted-input window is full",\n                )));\n''',
)
replace_once(
    runtime,
    '''                return Err(std::io::Error::new(\n                    std::io::ErrorKind::WouldBlock,\n                    "terminal host input request id exhausted",\n                ));\n''',
    '''                return Err(InputAckBeginFailure::Known(std::io::Error::new(\n                    std::io::ErrorKind::WouldBlock,\n                    "terminal host input request id exhausted",\n                )));\n''',
)
replace_once(
    runtime,
    '''                    return Err(std::io::Error::new(\n                        std::io::ErrorKind::WouldBlock,\n                        "terminal host input request id collision",\n                    ));\n''',
    '''                    return Err(InputAckBeginFailure::Known(std::io::Error::new(\n                        std::io::ErrorKind::WouldBlock,\n                        "terminal host input request id collision",\n                    )));\n''',
)
replace_once(
    runtime,
    '''                return Err(error);\n            }\n\n            Ok(InputAckReceipt {\n''',
    '''                return Err(InputAckBeginFailure::Ambiguous(error));\n            }\n\n            Ok(InputAckReceipt {\n''',
)
replace_once(
    runtime,
    '''            let error = match attachment.begin_input_confirmed(b"must-not-send") {\n                Ok(_) => panic!("legacy host accepted a receipted input request"),\n                Err(error) => error,\n            };\n            assert_eq!(error.kind(), std::io::ErrorKind::Unsupported);\n''',
    '''            let error = match attachment.begin_input_confirmed(b"must-not-send") {\n                Ok(_) => panic!("legacy host accepted a receipted input request"),\n                Err(InputAckBeginFailure::Known(error)) => error,\n                Err(InputAckBeginFailure::Ambiguous(error)) => {\n                    panic!("legacy-host rejection became ambiguous: {error}")\n                }\n            };\n            assert_eq!(error.kind(), std::io::ErrorKind::Unsupported);\n''',
)

surface = "cmux-tui/crates/cmux-tui-core/src/surface.rs"
replace_once(
    surface,
    '''/// Nonblocking probe for the terminal mouse protocol and reporting mode.\n''',
    '''/// Delivery classification for receipted terminal input.\n///\n/// `Known` means the implementation proved no bytes were submitted to the\n/// authoritative PTY owner. `Indeterminate` means bytes may have crossed a\n/// local writer or terminal-host socket before the failure became visible.\n#[derive(Debug)]\npub(crate) enum ConfirmedInputFailure {\n    Known(std::io::Error),\n    Indeterminate(std::io::Error),\n}\n\n/// Nonblocking probe for the terminal mouse protocol and reporting mode.\n''',
)
replace_once(
    surface,
    '''    pub(crate) fn write_bytes_confirmed(&self, bytes: &[u8]) -> std::io::Result<()> {\n        let Some(pty) = self.as_pty() else {\n            return Err(std::io::Error::new(\n                std::io::ErrorKind::Unsupported,\n                "browser surface does not accept PTY bytes",\n            ));\n        };\n        let mut runtime = pty.runtime.lock().unwrap();\n        match &mut *runtime {\n            PtyRuntime::Local { writer, .. } => {\n                writer.write_all(bytes)?;\n                writer.flush()\n            }\n            #[cfg(unix)]\n            PtyRuntime::Hosted(host) => {\n                let receipt = host.begin_input_confirmed(bytes)?;\n                drop(runtime);\n                receipt.wait()\n            }\n            #[cfg(unix)]\n            PtyRuntime::ExitedHosted => Err(std::io::Error::new(\n                std::io::ErrorKind::NotConnected,\n                "terminal has no live PTY owner for receipted input",\n            )),\n        }\n    }\n''',
    '''    pub(crate) fn write_bytes_confirmed(\n        &self,\n        bytes: &[u8],\n    ) -> Result<(), ConfirmedInputFailure> {\n        let Some(pty) = self.as_pty() else {\n            return Err(ConfirmedInputFailure::Known(std::io::Error::new(\n                std::io::ErrorKind::Unsupported,\n                "browser surface does not accept PTY bytes",\n            )));\n        };\n        let mut runtime = pty.runtime.lock().unwrap();\n        match &mut *runtime {\n            PtyRuntime::Local { writer, .. } => writer\n                .write_all(bytes)\n                .and_then(|()| writer.flush())\n                .map_err(ConfirmedInputFailure::Indeterminate),\n            #[cfg(unix)]\n            PtyRuntime::Hosted(host) => {\n                let receipt = host.begin_input_confirmed(bytes).map_err(|failure| match failure {\n                    crate::terminal_host_runtime::InputAckBeginFailure::Known(error) => {\n                        ConfirmedInputFailure::Known(error)\n                    }\n                    crate::terminal_host_runtime::InputAckBeginFailure::Ambiguous(error) => {\n                        ConfirmedInputFailure::Indeterminate(error)\n                    }\n                })?;\n                drop(runtime);\n                receipt.wait().map_err(ConfirmedInputFailure::Indeterminate)\n            }\n            #[cfg(unix)]\n            PtyRuntime::ExitedHosted => Err(ConfirmedInputFailure::Known(std::io::Error::new(\n                std::io::ErrorKind::NotConnected,\n                "terminal has no live PTY owner for receipted input",\n            ))),\n        }\n    }\n''',
)
replace_once(
    surface,
    '''    #[derive(Clone, Default)]\n    struct CapturingWriter(Arc<Mutex<Vec<u8>>>);\n''',
    '''    struct PartialWouldBlockWriter {\n        accepted_prefix: bool,\n    }\n\n    impl Write for PartialWouldBlockWriter {\n        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {\n            if !self.accepted_prefix && !bytes.is_empty() {\n                self.accepted_prefix = true;\n                return Ok(1);\n            }\n            Err(std::io::Error::new(\n                std::io::ErrorKind::WouldBlock,\n                "synthetic partial local PTY write",\n            ))\n        }\n\n        fn flush(&mut self) -> std::io::Result<()> {\n            Ok(())\n        }\n    }\n\n    #[derive(Clone, Default)]\n    struct CapturingWriter(Arc<Mutex<Vec<u8>>>);\n''',
)
replace_once(
    surface,
    '''    #[cfg(unix)]\n    #[test]\n    fn receipted_input_rejects_an_exited_host_before_effect() {\n        let mux = Mux::new_for_test("receipted-input-exited-host", SurfaceOptions::default());\n        let surface =\n            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();\n        let pty = surface.as_pty().unwrap();\n        {\n            let mut runtime = pty.runtime.lock().unwrap();\n            *runtime = PtyRuntime::ExitedHosted;\n        }\n\n        let error = surface.write_bytes_confirmed(b"must-not-drop").unwrap_err();\n        assert_eq!(error.kind(), std::io::ErrorKind::NotConnected);\n        assert!(error.to_string().contains("no live PTY owner"));\n    }\n\n''',
    '''    #[cfg(unix)]\n    #[test]\n    fn receipted_input_rejects_an_exited_host_before_effect() {\n        let mux = Mux::new_for_test("receipted-input-exited-host", SurfaceOptions::default());\n        let surface =\n            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();\n        let pty = surface.as_pty().unwrap();\n        {\n            let mut runtime = pty.runtime.lock().unwrap();\n            *runtime = PtyRuntime::ExitedHosted;\n        }\n\n        let error = surface.write_bytes_confirmed(b"must-not-drop").unwrap_err();\n        let ConfirmedInputFailure::Known(error) = error else {\n            panic!("exited-host rejection became indeterminate");\n        };\n        assert_eq!(error.kind(), std::io::ErrorKind::NotConnected);\n        assert!(error.to_string().contains("no live PTY owner"));\n    }\n\n    #[test]\n    fn receipted_input_local_partial_would_block_is_indeterminate() {\n        let mux = Mux::new_for_test("receipted-input-local-partial", SurfaceOptions::default());\n        let surface =\n            Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();\n        replace_local_writer(\n            &surface,\n            Box::new(PartialWouldBlockWriter { accepted_prefix: false }),\n        );\n\n        let error = surface.write_bytes_confirmed(b"ab").unwrap_err();\n        let ConfirmedInputFailure::Indeterminate(error) = error else {\n            panic!("partial local PTY write was incorrectly classified as known-not-delivered");\n        };\n        assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock);\n    }\n\n''',
)

content = "cmux-tui/crates/cmux-tui-core/src/resource_router/content.rs"
replace_once(
    content,
    '''fn confirmed_terminal_write(\n    surface: &Surface,\n    bytes: &[u8],\n    operation: &str,\n) -> Result<(), ActionFailure> {\n    match surface.write_bytes_confirmed(bytes) {\n        Ok(()) => Ok(()),\n        Err(error)\n            if matches!(\n                error.kind(),\n                std::io::ErrorKind::Unsupported\n                    | std::io::ErrorKind::WouldBlock\n                    | std::io::ErrorKind::NotConnected\n            ) =>\n        {\n            Err(ActionFailure::Known(ResourceError::operation_failed(\n                operation,\n                error.to_string(),\n                json!({}),\n            )))\n        }\n        Err(error) => Err(ActionFailure::Indeterminate(error.to_string())),\n    }\n}\n''',
    '''fn confirmed_terminal_write(\n    surface: &Surface,\n    bytes: &[u8],\n    operation: &str,\n) -> Result<(), ActionFailure> {\n    match surface.write_bytes_confirmed(bytes) {\n        Ok(()) => Ok(()),\n        Err(crate::surface::ConfirmedInputFailure::Known(error)) => {\n            Err(ActionFailure::Known(ResourceError::operation_failed(\n                operation,\n                error.to_string(),\n                json!({}),\n            )))\n        }\n        Err(crate::surface::ConfirmedInputFailure::Indeterminate(error)) => {\n            Err(ActionFailure::Indeterminate(error.to_string()))\n        }\n    }\n}\n''',
)
