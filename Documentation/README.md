# Luma 工程文档

本目录记录当前 iOS 客户端的实际实现，以及后端与端到端通信的设计。文中统一使用 **已实现**、**设计中**、**未来计划** 标记状态。后端基础工程已存在于 `backend/`；显式在线文字模式已在隔离后端和模拟器双账号间完成 v3 基础闭环，但尚未部署或完成双实体设备与安全审计。实际接口以 OpenAPI 和代码为准。

| 分类 | 文档 |
| --- | --- |
| 产品 | [产品需求](Product/Luma_PRD.md) · [功能路线图](Product/Feature_Roadmap.md) |
| 客户端架构 | [iOS 架构](Architecture/iOS_Client_Architecture.md) · [安全架构](Architecture/Security_Architecture.md) · [数据模型](Architecture/Data_Model.md) |
| 密码学 | [密钥管理](Crypto/Key_Management.md) · [E2EE 设计](Crypto/E2EE_Design.md) · [会话协议](Crypto/Session_Protocol.md) |
| 后端 | [后端架构](Backend/Backend_Architecture.md) · [API 规格](Backend/API_Specification.md) · [数据库设计](Backend/Database_Schema.md) |
| 协议 | [客户端与服务器](Protocol/Client_Server_Protocol.md) · [消息格式](Protocol/Message_Format.md) · [同步协议](Protocol/Sync_Protocol.md) |
| 安全 | [威胁模型](Security/Threat_Model.md) · [隐私模型](Security/Privacy_Model.md) · [上线前审计清单](Security/Security_Audit_Checklist.md) |

开发新功能前，先读对应的 Architecture、Security、Protocol 文档，并对照当前代码确认状态。若实现与文档不符，以代码的可验证行为为准，同时更新文档。不要把设计草案描述为已部署能力。
