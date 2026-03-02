import { LightningElement, api, track } from 'lwc';
import { FlowNavigationNextEvent } from 'lightning/flowSupport';
import fetchDocumentData from '@salesforce/apex/DocGenSignatureController.fetchDocumentData';

export default class DocGenSignaturePad extends LightningElement {
    @api token; 
    @api secureToken; 
    @api recordId;
    @api documentUrl;
    @api signatureData; 
    @api templateBase64;
    @api mergeDataJson;
    @api base64Pdf;
    @api pdfFileName;
    
    // Flow Actions
    @api availableActions = [];

    // State Flags
    @track isLocked = false;
    @track isProcessing = false;
    isDrawing = false;
    isCanvasEmpty = true;
    isDrawing = false;
    isCanvasEmpty = true;
    
    // Canvas Context
    ctx;
    canvasRect;
    lastX = 0;
    lastY = 0;

    get showPad() {
        return !this.isLocked && !this.isProcessing;
    }

    connectedCallback() {
        this.initData();
    }

    async initData() {
        const activeToken = this.token || this.secureToken;
        if (activeToken) {
            try {
                const res = await fetchDocumentData({ token: activeToken });
                if (res.isValid) {
                    this.templateBase64 = res.templateBase64;
                    this.recordId = res.recordId;
                    this.mergeDataJson = res.mergeDataJson;
                }
            } catch (error) {
            }
        }
    }

    renderedCallback() {
        if (!this.ctx && this.showPad) {
            setTimeout(() => {
                this.initCanvas();
            }, 100);
        }
    }

    initCanvas() {
        const canvas = this.template.querySelector('.signature-pad');
        if (canvas) {
            const wrapper = this.template.querySelector('.canvas-wrapper');
            canvas.width = wrapper.offsetWidth;
            canvas.height = 300; 

            this.ctx = canvas.getContext('2d');
            this.ctx.strokeStyle = '#000000';
            this.ctx.lineJoin = 'round';
            this.ctx.lineCap = 'round';
            this.ctx.lineWidth = 3; 
        }
    }

    // --- Drawing Events ---
    handleMousedown(e) {
        this.ctx.beginPath();
        this.isDrawing = true;
        this.updateCoordinates(e.clientX, e.clientY);
    }
    handleMousemove(e) {
        if (!this.isDrawing) return;
        this.draw(e.clientX, e.clientY);
    }
    handleMouseup() { this.isDrawing = false; }
    handleTouchstart(e) {
        e.preventDefault();
        if (e.touches.length > 0) {
            this.ctx.beginPath();
            this.isDrawing = true;
            this.updateCoordinates(e.touches[0].clientX, e.touches[0].clientY);
        }
    }
    handleTouchmove(e) {
        e.preventDefault();
        if (!this.isDrawing) return;
        if (e.touches.length > 0) this.draw(e.touches[0].clientX, e.touches[0].clientY);
    }
    handleTouchend(e) { e.preventDefault(); this.isDrawing = false; }

    updateCoordinates(clientX, clientY) {
        const canvas = this.template.querySelector('.signature-pad');
        if (!canvas) return;
        this.canvasRect = canvas.getBoundingClientRect();
        this.lastX = clientX - this.canvasRect.left;
        this.lastY = clientY - this.canvasRect.top;
    }

    draw(clientX, clientY) {
        const currentX = clientX - this.canvasRect.left;
        const currentY = clientY - this.canvasRect.top;
        this.ctx.moveTo(this.lastX, this.lastY);
        this.ctx.lineTo(currentX, currentY);
        this.ctx.stroke();
        this.lastX = currentX;
        this.lastY = currentY;
        if (this.isCanvasEmpty) this.isCanvasEmpty = false;
    }

    clearSignature() {
        const canvas = this.template.querySelector('.signature-pad');
        this.ctx.clearRect(0, 0, canvas.width, canvas.height);
        this.isCanvasEmpty = true;
    }

    async saveSignature() {
        if (this.isCanvasEmpty) return;

        this.isProcessing = true;
        const activeToken = this.token || this.secureToken;

        try {
            // 1. Get Signature Image
            const canvas = this.template.querySelector('.signature-pad');

            // Stamp date/time onto the signature image
            const now = new Date();
            const timestamp = now.toLocaleString(undefined, {
                year: 'numeric', month: '2-digit', day: '2-digit',
                hour: '2-digit', minute: '2-digit', second: '2-digit'
            });
            this.ctx.save();
            this.ctx.font = 'bold 28px Arial, sans-serif';
            this.ctx.fillStyle = '#000000';
            this.ctx.textAlign = 'right';
            this.ctx.textBaseline = 'bottom';
            this.ctx.fillText('Signed: ' + timestamp, canvas.width - 10, canvas.height - 10);
            this.ctx.restore();

            const dataUrl = canvas.toDataURL('image/png');
            this.signatureData = dataUrl.split(',')[1];

            this.isLocked = true;
            this.dispatchEvent(new CustomEvent('signaturesuccess', { detail: { token: activeToken } }));

            // 2. AUTO-ADVANCE FLOW
            if (this.availableActions && this.availableActions.find(action => action === 'NEXT')) {
                const navigateNextEvent = new FlowNavigationNextEvent();
                this.dispatchEvent(navigateNextEvent);
            }

        } catch (error) {
            const errorMsg = error.body ? error.body.message : (error.message || JSON.stringify(error));
            alert('Error capturing signature: ' + errorMsg);
        } finally {
            this.isProcessing = false;
        }
    }


}