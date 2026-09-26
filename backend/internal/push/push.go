package push

// Sender is an integration boundary. This backend does not contact APNs yet.
type Sender interface{ NotifyNewMessage(deviceID string) error }
type Disabled struct{}

func (Disabled) NotifyNewMessage(string) error { return nil }

const GenericNotification = "收到新消息"
