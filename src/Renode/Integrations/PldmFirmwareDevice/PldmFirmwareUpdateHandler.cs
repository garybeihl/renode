//
// Copyright (c) 2026 Microsoft
//
// This file is licensed under the MIT License.
// Full license text is available in 'licenses/MIT.txt'.
//
using System;
using System.Collections.Generic;
using Antmicro.Renode.Logging;

namespace Antmicro.Renode.Integrations
{
    // PLDM Firmware Update handler — FD state machine (DSP0267)
    // States: IDLE → LEARN_COMPONENTS → READY_XFER → DOWNLOAD → VERIFY → APPLY → ACTIVATE
    public class PldmFirmwareUpdateHandler
    {
        public enum FdState
        {
            Idle = 0,
            LearnComponents = 1,
            ReadyXfer = 2,
            Download = 3,
            Verify = 4,
            Apply = 5,
            Activate = 6,
        }

        private FdState state = FdState.Idle;
        private FdState previousState = FdState.Idle;

        private readonly ScenarioConfig config;
        private readonly IEmulationElement logger;

        // Update session state
        private uint maxTransferSize;
        private int componentIndex; // index into config.Components for current update
        private uint downloadOffset;
        private uint downloadLength; // comp_image_size for current component
        private uint fwDataReceived;
        private byte fdInstanceId; // instance ID for FD-initiated requests
        private List<int> updatableComponents; // indices of components that can be updated

        // Pending FD-initiated message
        private byte[] pendingFdRequest;

        public PldmFirmwareUpdateHandler(ScenarioConfig config, IEmulationElement logger)
        {
            this.config = config;
            this.logger = logger;
            updatableComponents = new List<int>();
        }

        public FdState State { get { return state; } }

        // Handle an incoming PLDM firmware update request
        // Returns response PLDM message, and sets pendingFdRequest if FD needs to send
        public byte[] HandleRequest(byte[] pldmMsg)
        {
            if(pldmMsg == null || pldmMsg.Length < 3)
            {
                return null;
            }

            byte instanceId, pldmType, command;
            bool request, datagram;
            PldmEncoder.ParseHeader(pldmMsg, out instanceId, out request, out datagram, out pldmType, out command);

            if(!request)
            {
                // This is a response to our FD-initiated request
                return HandleFdResponse(pldmMsg, command);
            }

            logger.Log(LogLevel.Debug, "PLDM FWUP: command 0x{0:X2}, instance {1}, state {2}", command, instanceId, state);

            switch(command)
            {
                case PldmEncoder.CmdQueryDeviceIdentifiers:
                    return HandleQueryDeviceIdentifiers(instanceId);

                case PldmEncoder.CmdGetFirmwareParameters:
                    return HandleGetFirmwareParameters(instanceId);

                case PldmEncoder.CmdRequestUpdate:
                    return HandleRequestUpdate(instanceId, pldmMsg);

                case PldmEncoder.CmdPassComponentTable:
                    return HandlePassComponentTable(instanceId, pldmMsg);

                case PldmEncoder.CmdUpdateComponent:
                    return HandleUpdateComponent(instanceId, pldmMsg);

                case PldmEncoder.CmdActivateFirmware:
                    return HandleActivateFirmware(instanceId, pldmMsg);

                case PldmEncoder.CmdGetStatus:
                    return HandleGetStatus(instanceId);

                case PldmEncoder.CmdCancelUpdateComponent:
                    return HandleCancelUpdateComponent(instanceId);

                case PldmEncoder.CmdCancelUpdate:
                    return HandleCancelUpdate(instanceId);

                default:
                    logger.Log(LogLevel.Debug, "PLDM FWUP: unsupported command 0x{0:X2}", command);
                    return BuildErrorResponse(instanceId, command, PldmEncoder.ErrorUnsupportedPldmCmd);
            }
        }

        // Get pending FD-initiated request (null if none)
        public byte[] GetPendingFdRequest()
        {
            var req = pendingFdRequest;
            pendingFdRequest = null;
            return req;
        }

        // QueryDeviceIdentifiers — always allowed
        private byte[] HandleQueryDeviceIdentifiers(byte instanceId)
        {
            logger.Log(LogLevel.Info, "PLDM FWUP: QueryDeviceIdentifiers");

            // Response: Header(3) + CC(1) + device_identifiers_len(4) + descriptor_count(1) +
            //           descriptor_type(2) + descriptor_len(2) + descriptor_data(16) = 29
            var resp = new byte[29];
            var hdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypeFirmwareUpdate,
                PldmEncoder.CmdQueryDeviceIdentifiers);
            Array.Copy(hdr, 0, resp, 0, 3);
            resp[3] = PldmEncoder.Success;

            // device_identifiers_len = sum of descriptor TLVs only (not descriptor_count)
            // 1 descriptor: type(2) + len(2) + data(16) = 20
            PldmEncoder.WriteLE32(resp, 4, 20);
            resp[8] = 1; // descriptor count

            // UUID descriptor
            PldmEncoder.WriteLE16(resp, 9, PldmEncoder.DescriptorTypeUuid);
            PldmEncoder.WriteLE16(resp, 11, 16);
            Array.Copy(config.Uuid, 0, resp, 13, 16);
            return resp;
        }

        // GetFirmwareParameters — always allowed
        private byte[] HandleGetFirmwareParameters(byte instanceId)
        {
            logger.Log(LogLevel.Info, "PLDM FWUP: GetFirmwareParameters");

            // Build component table entries
            var compEntries = new List<byte[]>();
            foreach(var comp in config.Components)
            {
                var verBytes = System.Text.Encoding.ASCII.GetBytes(comp.Version);
                // Component parameter entry per DSP0267 Table 24 / pldm_component_parameter_entry:
                //   comp_classification(2) + comp_identifier(2) + comp_classification_index(1) +
                //   active_comp_comparison_stamp(4) + active_comp_ver_str_type(1) +
                //   active_comp_ver_str_len(1) + active_comp_release_date(8) +
                //   pending_comp_comparison_stamp(4) + pending_comp_ver_str_type(1) +
                //   pending_comp_ver_str_len(1) + pending_comp_release_date(8) +
                //   comp_activation_methods(2) + capabilities_during_update(4) = 39 fixed
                //   + active_comp_ver_str(N) + pending_comp_ver_str(0)
                var entry = new byte[39 + verBytes.Length];
                PldmEncoder.WriteLE16(entry, 0, comp.Classification);
                PldmEncoder.WriteLE16(entry, 2, comp.Id);
                entry[4] = 0; // comp_classification_index
                PldmEncoder.WriteLE32(entry, 5, 0); // active_comp_comparison_stamp
                entry[9] = 0x01; // active_comp_ver_str_type: ASCII
                entry[10] = (byte)verBytes.Length; // active_comp_ver_str_len
                // active_comp_release_date: 8 bytes of 0 at offset 11
                PldmEncoder.WriteLE32(entry, 19, 0); // pending_comp_comparison_stamp
                entry[23] = 0x00; // pending_comp_ver_str_type: unknown (no pending)
                entry[24] = 0x00; // pending_comp_ver_str_len
                // pending_comp_release_date: 8 bytes of 0 at offset 25
                PldmEncoder.WriteLE16(entry, 33, 0x0001); // comp_activation_methods: automatic
                PldmEncoder.WriteLE32(entry, 35, 0x000E); // capabilities_during_update
                Array.Copy(verBytes, 0, entry, 39, verBytes.Length);
                compEntries.Add(entry);
            }

            // Calculate total component entries size
            int compEntriesSize = 0;
            foreach(var e in compEntries) compEntriesSize += e.Length;

            var activeVerBytes = System.Text.Encoding.ASCII.GetBytes(config.ImageSetVersion);

            // Response: Header(3) + CC(1) + capabilities(4) + comp_count(2) +
            //   active_comp_image_set_ver_str_type(1) + active_ver_str_len(1) +
            //   pending_comp_image_set_ver_str_type(1) + pending_ver_str_len(1) +
            //   active_ver_str(N) + pending_ver_str(0) + component entries
            int respLen = 14 + activeVerBytes.Length + compEntriesSize;
            var resp = new byte[respLen];
            var hdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypeFirmwareUpdate,
                PldmEncoder.CmdGetFirmwareParameters);
            Array.Copy(hdr, 0, resp, 0, 3);
            resp[3] = PldmEncoder.Success;

            PldmEncoder.WriteLE32(resp, 4, 0x000E); // capabilities
            PldmEncoder.WriteLE16(resp, 8, (ushort)config.Components.Count);
            resp[10] = 0x01; // active ver str type: ASCII
            resp[11] = (byte)activeVerBytes.Length;
            resp[12] = 0x00; // pending ver str type: unknown
            resp[13] = 0x00; // pending ver str len

            int offset = 14;
            Array.Copy(activeVerBytes, 0, resp, offset, activeVerBytes.Length);
            offset += activeVerBytes.Length;
            // no pending version string

            foreach(var entry in compEntries)
            {
                Array.Copy(entry, 0, resp, offset, entry.Length);
                offset += entry.Length;
            }

            return resp;
        }

        // RequestUpdate — IDLE only → LEARN_COMPONENTS
        private byte[] HandleRequestUpdate(byte instanceId, byte[] pldmMsg)
        {
            if(state != FdState.Idle)
            {
                logger.Log(LogLevel.Warning, "PLDM FWUP: RequestUpdate in state {0}", state);
                return BuildErrorResponse(instanceId, PldmEncoder.CmdRequestUpdate,
                    state == FdState.Idle ? PldmEncoder.Error : PldmEncoder.FwupAlreadyInUpdateMode);
            }

            // Parse: max_transfer_size(4) + num_components(2) + max_outstanding(1) +
            //   pkg_data_len(2) + comp_image_set_ver_str_type(1) + comp_image_set_ver_str_len(1)
            if(pldmMsg.Length < 14)
            {
                return BuildErrorResponse(instanceId, PldmEncoder.CmdRequestUpdate, PldmEncoder.Error);
            }

            maxTransferSize = PldmEncoder.ReadLE32(pldmMsg, 3);
            if(maxTransferSize > config.MaxTransferSize)
            {
                maxTransferSize = config.MaxTransferSize;
            }
            if(maxTransferSize < 32)
            {
                maxTransferSize = 32;
            }

            logger.Log(LogLevel.Info, "PLDM FWUP: RequestUpdate, max_transfer={0}", maxTransferSize);

            TransitionTo(FdState.LearnComponents);
            updatableComponents.Clear();
            componentIndex = -1;

            // Response: Header(3) + CC(1) + fd_meta_data_len(2) + fd_will_send_pkg_data(1) = 7
            var resp = new byte[7];
            var hdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypeFirmwareUpdate,
                PldmEncoder.CmdRequestUpdate);
            Array.Copy(hdr, 0, resp, 0, 3);
            resp[3] = PldmEncoder.Success;
            PldmEncoder.WriteLE16(resp, 4, 0); // fd_meta_data_len = 0
            resp[6] = 0x00; // fd_will_send_pkg_data = no
            return resp;
        }

        // PassComponentTable — LEARN_COMPONENTS → (eventually) READY_XFER
        private byte[] HandlePassComponentTable(byte instanceId, byte[] pldmMsg)
        {
            if(state != FdState.LearnComponents)
            {
                return BuildErrorResponse(instanceId, PldmEncoder.CmdPassComponentTable,
                    PldmEncoder.FwupInvalidStateForCommand);
            }

            // Parse: transfer_flag(1) + comp_classification(2) + comp_identifier(2) + ...
            if(pldmMsg.Length < 8)
            {
                return BuildErrorResponse(instanceId, PldmEncoder.CmdPassComponentTable, PldmEncoder.Error);
            }

            byte transferFlag = pldmMsg[3];
            ushort compClassification = PldmEncoder.ReadLE16(pldmMsg, 4);
            ushort compId = PldmEncoder.ReadLE16(pldmMsg, 6);

            logger.Log(LogLevel.Info, "PLDM FWUP: PassComponentTable, comp_id={0}, transfer_flag=0x{1:X2}",
                compId, transferFlag);

            // Find component in config
            byte compResponse = PldmEncoder.CompCanBeUpdated;
            byte compResponseCode = 0x00;
            for(int i = 0; i < config.Components.Count; i++)
            {
                if(config.Components[i].Id == compId)
                {
                    if(!config.Components[i].CanUpdate)
                    {
                        compResponse = 0x01; // COMP_CANNOT_BE_UPDATED
                        compResponseCode = config.Components[i].RejectReason;
                        logger.Log(LogLevel.Info, "  -> comp {0}: CANNOT_BE_UPDATED (reason 0x{1:X2})", compId, compResponseCode);
                    }
                    else
                    {
                        logger.Log(LogLevel.Info, "  -> comp {0}: CAN_BE_UPDATED", compId);
                    }
                    break;
                }
            }

            // Check if this is the last entry
            bool isEnd = (transferFlag & 0x04) != 0; // TransferEnd bit
            if(isEnd)
            {
                TransitionTo(FdState.ReadyXfer);
            }

            // Response: Header(3) + CC(1) + comp_response(1) + comp_response_code(1) = 6
            var resp = new byte[6];
            var hdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypeFirmwareUpdate,
                PldmEncoder.CmdPassComponentTable);
            Array.Copy(hdr, 0, resp, 0, 3);
            resp[3] = PldmEncoder.Success;
            resp[4] = compResponse;
            resp[5] = compResponseCode;
            return resp;
        }

        // UpdateComponent — READY_XFER → DOWNLOAD
        private byte[] HandleUpdateComponent(byte instanceId, byte[] pldmMsg)
        {
            if(state != FdState.ReadyXfer)
            {
                return BuildErrorResponse(instanceId, PldmEncoder.CmdUpdateComponent,
                    PldmEncoder.FwupInvalidStateForCommand);
            }

            // Parse: comp_classification(2) + comp_identifier(2) + comp_classification_index(1) +
            //   comp_comparison_stamp(4) + comp_image_size(4) + update_option_flags(4) +
            //   requested_comp_activation_method(2) = 19 bytes of payload
            if(pldmMsg.Length < 22)
            {
                return BuildErrorResponse(instanceId, PldmEncoder.CmdUpdateComponent, PldmEncoder.Error);
            }

            ushort compId = PldmEncoder.ReadLE16(pldmMsg, 5);
            downloadLength = PldmEncoder.ReadLE32(pldmMsg, 12);
            downloadOffset = 0;
            fwDataReceived = 0;

            logger.Log(LogLevel.Info, "PLDM FWUP: UpdateComponent, comp_id={0}, image_size={1}", compId, downloadLength);

            // Find component
            componentIndex = -1;
            for(int i = 0; i < config.Components.Count; i++)
            {
                if(config.Components[i].Id == compId)
                {
                    componentIndex = i;
                    break;
                }
            }

            byte compCompatResponse = PldmEncoder.CompCanBeUpdated;
            byte compCompatCode = 0x00;

            if(componentIndex >= 0 && !config.Components[componentIndex].CanUpdate)
            {
                compCompatResponse = 0x01;
                compCompatCode = config.Components[componentIndex].RejectReason;
                logger.Log(LogLevel.Info, "  -> comp {0}: CANNOT_BE_UPDATED", compId);
            }
            else
            {
                TransitionTo(FdState.Download);
                // Queue RequestFirmwareData
                QueueRequestFirmwareData();
            }

            // Response: Header(3) + CC(1) + comp_compatibility_response(1) +
            //   comp_compatibility_response_code(1) + update_option_flags_used(4) +
            //   estimated_time(2) = 12
            var resp = new byte[12];
            var hdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypeFirmwareUpdate,
                PldmEncoder.CmdUpdateComponent);
            Array.Copy(hdr, 0, resp, 0, 3);
            resp[3] = PldmEncoder.Success;
            resp[4] = compCompatResponse;
            resp[5] = compCompatCode;
            PldmEncoder.WriteLE32(resp, 6, 0); // update_option_flags_used
            PldmEncoder.WriteLE16(resp, 10, 0); // estimated_time = immediate
            return resp;
        }

        // ActivateFirmware — READY_XFER → ACTIVATE
        private byte[] HandleActivateFirmware(byte instanceId, byte[] pldmMsg)
        {
            if(state != FdState.ReadyXfer)
            {
                return BuildErrorResponse(instanceId, PldmEncoder.CmdActivateFirmware,
                    PldmEncoder.FwupInvalidStateForCommand);
            }

            bool selfContained = pldmMsg.Length > 3 && pldmMsg[3] != 0;
            logger.Log(LogLevel.Info, "PLDM FWUP: ActivateFirmware, self_contained={0}", selfContained);

            TransitionTo(FdState.Activate);
            // After activation, return to idle
            TransitionTo(FdState.Idle);

            // Response: Header(3) + CC(1) + estimated_time(2) = 6
            var resp = new byte[6];
            var hdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypeFirmwareUpdate,
                PldmEncoder.CmdActivateFirmware);
            Array.Copy(hdr, 0, resp, 0, 3);
            resp[3] = PldmEncoder.Success;
            PldmEncoder.WriteLE16(resp, 4, 0); // estimated_time = 0 (immediate)
            return resp;
        }

        // GetStatus — any state
        private byte[] HandleGetStatus(byte instanceId)
        {
            logger.Log(LogLevel.Debug, "PLDM FWUP: GetStatus, state={0}", state);

            // Response: Header(3) + CC(1) + current_state(1) + previous_state(1) +
            //   aux_state(1) + aux_state_status(1) + progress_percent(1) +
            //   reason_code(1) + update_option_flags(4) = 14
            var resp = new byte[14];
            var hdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypeFirmwareUpdate,
                PldmEncoder.CmdGetStatus);
            Array.Copy(hdr, 0, resp, 0, 3);
            resp[3] = PldmEncoder.Success;
            resp[4] = (byte)state;
            resp[5] = (byte)previousState;
            resp[6] = 0; // aux_state: in progress / idle
            resp[7] = 0; // aux_state_status
            resp[8] = 0; // progress_percent (0 = not reported)
            resp[9] = 0; // reason_code
            PldmEncoder.WriteLE32(resp, 10, 0); // update_option_flags
            return resp;
        }

        // CancelUpdateComponent — DOWNLOAD/VERIFY/APPLY → READY_XFER
        private byte[] HandleCancelUpdateComponent(byte instanceId)
        {
            if(state != FdState.Download && state != FdState.Verify && state != FdState.Apply)
            {
                return BuildErrorResponse(instanceId, PldmEncoder.CmdCancelUpdateComponent,
                    PldmEncoder.FwupInvalidStateForCommand);
            }

            logger.Log(LogLevel.Info, "PLDM FWUP: CancelUpdateComponent");
            pendingFdRequest = null;
            TransitionTo(FdState.ReadyXfer);

            var resp = new byte[4];
            var hdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypeFirmwareUpdate,
                PldmEncoder.CmdCancelUpdateComponent);
            Array.Copy(hdr, 0, resp, 0, 3);
            resp[3] = PldmEncoder.Success;
            return resp;
        }

        // CancelUpdate — any non-IDLE → IDLE
        private byte[] HandleCancelUpdate(byte instanceId)
        {
            if(state == FdState.Idle)
            {
                return BuildErrorResponse(instanceId, PldmEncoder.CmdCancelUpdate,
                    PldmEncoder.FwupNotInUpdateMode);
            }

            logger.Log(LogLevel.Info, "PLDM FWUP: CancelUpdate");
            pendingFdRequest = null;
            TransitionTo(FdState.Idle);

            // Response: Header(3) + CC(1) + non_functioning_component_indication(1) +
            //   non_functioning_component_bitmap(8) = 13
            var resp = new byte[13];
            var hdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypeFirmwareUpdate,
                PldmEncoder.CmdCancelUpdate);
            Array.Copy(hdr, 0, resp, 0, 3);
            resp[3] = PldmEncoder.Success;
            resp[4] = 0; // no non-functioning components
            // bitmap bytes 5-12 are 0
            return resp;
        }

        // Handle response to an FD-initiated request
        private byte[] HandleFdResponse(byte[] pldmMsg, byte command)
        {
            if(pldmMsg.Length < 4)
            {
                return null;
            }

            byte completionCode = pldmMsg[3];
            logger.Log(LogLevel.Debug, "PLDM FWUP: FD response for command 0x{0:X2}, CC={1}", command, completionCode);

            switch(command)
            {
                case PldmEncoder.CmdRequestFirmwareData:
                    return HandleFirmwareDataResponse(pldmMsg);

                case PldmEncoder.CmdTransferComplete:
                    return HandleTransferCompleteResponse(pldmMsg);

                case PldmEncoder.CmdVerifyComplete:
                    return HandleVerifyCompleteResponse(pldmMsg);

                case PldmEncoder.CmdApplyComplete:
                    return HandleApplyCompleteResponse(pldmMsg);

                default:
                    logger.Log(LogLevel.Warning, "PLDM FWUP: unexpected FD response for command 0x{0:X2}", command);
                    return null;
            }
        }

        // Handle firmware data received from UA
        private byte[] HandleFirmwareDataResponse(byte[] pldmMsg)
        {
            if(state != FdState.Download)
            {
                logger.Log(LogLevel.Warning, "PLDM FWUP: FirmwareData response in state {0}", state);
                return null;
            }

            byte cc = pldmMsg[3];
            if(cc != PldmEncoder.Success)
            {
                logger.Log(LogLevel.Warning, "PLDM FWUP: FirmwareData failed, CC={0}", cc);
                // Send TransferComplete with failure
                QueueTransferComplete(0x03); // FD_ABORTED_TRANSFER
                return null;
            }

            // Data follows CC at offset 4
            uint dataLen = (uint)(pldmMsg.Length - 4);
            fwDataReceived += dataLen;
            downloadOffset += dataLen;

            logger.Log(LogLevel.Debug, "PLDM FWUP: FirmwareData: offset={0}, received={1}/{2}",
                downloadOffset, fwDataReceived, downloadLength);

            if(downloadOffset >= downloadLength)
            {
                // Download complete
                logger.Log(LogLevel.Info, "PLDM FWUP: Download complete, total={0}", fwDataReceived);
                QueueTransferComplete(PldmEncoder.TransferSuccess);
            }
            else
            {
                // Request more data
                QueueRequestFirmwareData();
            }

            return null; // no PLDM response to send (we process the response internally)
        }

        private byte[] HandleTransferCompleteResponse(byte[] pldmMsg)
        {
            if(state != FdState.Download)
            {
                return null;
            }

            logger.Log(LogLevel.Info, "PLDM FWUP: TransferComplete acknowledged, entering VERIFY");
            TransitionTo(FdState.Verify);

            // Do verification
            byte verifyResult = PldmEncoder.VerifySuccess;
            if(componentIndex >= 0 && componentIndex < config.Components.Count)
            {
                verifyResult = config.Components[componentIndex].VerifyResult;
            }

            logger.Log(LogLevel.Info, "PLDM FWUP: Verify result: {0}",
                verifyResult == PldmEncoder.VerifySuccess ? "SUCCESS" : "FAILURE");

            QueueVerifyComplete(verifyResult);
            return null;
        }

        private byte[] HandleVerifyCompleteResponse(byte[] pldmMsg)
        {
            if(state != FdState.Verify)
            {
                return null;
            }

            logger.Log(LogLevel.Info, "PLDM FWUP: VerifyComplete acknowledged, entering APPLY");
            TransitionTo(FdState.Apply);

            // Do apply
            byte applyResult = PldmEncoder.ApplySuccess;
            if(componentIndex >= 0 && componentIndex < config.Components.Count)
            {
                applyResult = config.Components[componentIndex].ApplyResult;
            }

            logger.Log(LogLevel.Info, "PLDM FWUP: Apply result: {0}",
                applyResult == PldmEncoder.ApplySuccess ? "SUCCESS" : "FAILURE");

            QueueApplyComplete(applyResult);
            return null;
        }

        private byte[] HandleApplyCompleteResponse(byte[] pldmMsg)
        {
            if(state != FdState.Apply)
            {
                return null;
            }

            logger.Log(LogLevel.Info, "PLDM FWUP: ApplyComplete acknowledged, returning to READY_XFER");
            TransitionTo(FdState.ReadyXfer);
            return null;
        }

        // Queue FD-initiated RequestFirmwareData
        private void QueueRequestFirmwareData()
        {
            uint remaining = downloadLength - downloadOffset;
            uint requestLen = maxTransferSize;
            if(requestLen > remaining) requestLen = remaining;

            // Build PLDM request: Header(3) + offset(4) + length(4) = 11
            var pldmReq = new byte[11];
            var hdr = PldmEncoder.BuildRequestHeader(fdInstanceId, PldmEncoder.TypeFirmwareUpdate,
                PldmEncoder.CmdRequestFirmwareData);
            Array.Copy(hdr, 0, pldmReq, 0, 3);
            PldmEncoder.WriteLE32(pldmReq, 3, downloadOffset);
            PldmEncoder.WriteLE32(pldmReq, 7, requestLen);

            pendingFdRequest = pldmReq;
            fdInstanceId = (byte)((fdInstanceId + 1) & 0x1F);
        }

        // Queue FD-initiated TransferComplete
        private void QueueTransferComplete(byte transferResult)
        {
            // Build PLDM request: Header(3) + transfer_result(1) = 4
            var pldmReq = new byte[4];
            var hdr = PldmEncoder.BuildRequestHeader(fdInstanceId, PldmEncoder.TypeFirmwareUpdate,
                PldmEncoder.CmdTransferComplete);
            Array.Copy(hdr, 0, pldmReq, 0, 3);
            pldmReq[3] = transferResult;

            pendingFdRequest = pldmReq;
            fdInstanceId = (byte)((fdInstanceId + 1) & 0x1F);
        }

        // Queue FD-initiated VerifyComplete
        private void QueueVerifyComplete(byte verifyResult)
        {
            // Build PLDM request: Header(3) + verify_result(1) = 4
            var pldmReq = new byte[4];
            var hdr = PldmEncoder.BuildRequestHeader(fdInstanceId, PldmEncoder.TypeFirmwareUpdate,
                PldmEncoder.CmdVerifyComplete);
            Array.Copy(hdr, 0, pldmReq, 0, 3);
            pldmReq[3] = verifyResult;

            pendingFdRequest = pldmReq;
            fdInstanceId = (byte)((fdInstanceId + 1) & 0x1F);
        }

        // Queue FD-initiated ApplyComplete
        private void QueueApplyComplete(byte applyResult)
        {
            // Build PLDM request: Header(3) + apply_result(1) + comp_activation_methods_modification(2) = 6
            var pldmReq = new byte[6];
            var hdr = PldmEncoder.BuildRequestHeader(fdInstanceId, PldmEncoder.TypeFirmwareUpdate,
                PldmEncoder.CmdApplyComplete);
            Array.Copy(hdr, 0, pldmReq, 0, 3);
            pldmReq[3] = applyResult;
            PldmEncoder.WriteLE16(pldmReq, 4, 0); // no activation method modification

            pendingFdRequest = pldmReq;
            fdInstanceId = (byte)((fdInstanceId + 1) & 0x1F);
        }

        private void TransitionTo(FdState newState)
        {
            previousState = state;
            state = newState;
            logger.Log(LogLevel.Info, "PLDM FWUP: {0} → {1}", previousState, newState);
        }

        private byte[] BuildErrorResponse(byte instanceId, byte command, byte errorCode)
        {
            var resp = new byte[4];
            var hdr = PldmEncoder.BuildResponseHeader(instanceId, PldmEncoder.TypeFirmwareUpdate, command);
            Array.Copy(hdr, 0, resp, 0, 3);
            resp[3] = errorCode;
            return resp;
        }
    }
}
