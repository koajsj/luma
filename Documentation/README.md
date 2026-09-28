# Luma 工程文档

本目录记录 iOS 客户端、后端基础工程及通信协议的实际范围。文中区分 **已实现**、**局部验证** 和 **未完成**。显式在线模式已有 v4 文字、附件和控制事件代码；两台独立模拟器完成本地后端的文字与控制事件联调。附件全链路、两台实体设备、生产部署及独立安全审计尚未验收。实际 API 字段以 [OpenAPI](../backend/openapi/openapi.yaml) 和代码为准。

| 分类 | 文档 |
| --- | --- |
| 产品 | [产品需求](Product/Luma_PRD.md) · [功能路线图](Product/Feature_Roadmap.md) |
| 客户端架构 | [iOS 架构](Architecture/iOS_Client_Architecture.md) · [安全架构](Architecture/Security_Architecture.md) · [数据模型](Architecture/Data_Model.md) |
| 密码学 | [密钥管理](Crypto/Key_Management.md) · [E2EE 设计](Crypto/E2EE_Design.md) · [会话协议](Crypto/Session_Protocol.md) |
| 后端 | [后端架构](Backend/Backend_Architecture.md) · [API 规格](Backend/API_Specification.md) · [数据库设计](Backend/Database_Schema.md) |
| 协议 | [客户端与服务器](Protocol/Client_Server_Protocol.md) · [消息格式](Protocol/Message_Format.md) · [同步协议](Protocol/Sync_Protocol.md) |
| 安全 | [威胁模型](Security/Threat_Model.md) · [隐私模型](Security/Privacy_Model.md) · [上线前审计清单](Security/Security_Audit_Checklist.md) |

开发新功能前，先读对应的 Architecture、Security、Protocol 文档，并对照当前代码确认状态。若实现与文档不符，以代码的可验证行为为准，同时更新文档。不要把设计草案描述为已部署能力。
