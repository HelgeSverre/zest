import Foundation

enum PreviewRequest: Equatable {
  case custom(URL, PreviewFormat)
  case quickLook(URL)

  static func route(url: URL, isRegularFile: Bool) -> PreviewRequest {
    if isRegularFile,
      let format = PreviewFormat.customFormat(for: url, isDirectory: false)
    {
      return .custom(url, format)
    }
    return .quickLook(url)
  }

  var state: PreviewState {
    switch self {
    case .custom(let url, let format):
      .custom(url, format)
    case .quickLook(let url):
      .quickLook(url)
    }
  }
}

enum PreviewEvent: Equatable {
  case toggle(PreviewRequest)
  case selectionChanged(PreviewRequest)
  case close
}

enum PreviewState: Equatable {
  case closed
  case custom(URL, PreviewFormat)
  case quickLook(URL)

  var isOpen: Bool {
    self != .closed
  }

  static func reduce(_ state: PreviewState, event: PreviewEvent) -> PreviewState {
    switch event {
    case .toggle(let request):
      state.isOpen ? .closed : request.state
    case .selectionChanged(let request):
      state.isOpen ? request.state : .closed
    case .close:
      .closed
    }
  }
}
